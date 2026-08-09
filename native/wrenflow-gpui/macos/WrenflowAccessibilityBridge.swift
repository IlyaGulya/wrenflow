import AppKit

private struct WrenflowAccessibilityFrame: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
            x >= 0 && y >= 0 && width > 0 && height > 0
    }
}

private struct WrenflowAccessibilityNodeSnapshot: Decodable {
    let id: String
    let parentID: String?
    let role: String
    let label: String
    let value: String?
    let minimumValue: Double?
    let maximumValue: Double?
    let enabled: Bool
    let focused: Bool
    let actions: [String]
    let frame: WrenflowAccessibilityFrame
    let order: UInt32
}

private struct WrenflowAccessibilityAnnouncement: Decodable {
    let serial: UInt64
    let message: String
    let priority: String
}

private struct WrenflowAccessibilitySnapshot: Decodable {
    let generation: UInt64
    let coordinateSpace: String
    let nodes: [WrenflowAccessibilityNodeSnapshot]
    let focusedID: String?
    let announcement: WrenflowAccessibilityAnnouncement?
}

private struct WrenflowAccessibilityActionPayload: Encodable {
    let id: String
    let action: String
    let value: String?
}

private enum WrenflowAccessibilitySchema {
    static let roles: Set<String> = [
        "window", "button", "switch", "textField", "listBox", "slider", "progressIndicator",
        "dialog", "navigation", "status", "group", "heading", "staticText"
    ]
    static let actions: Set<String> = [
        "press", "focus", "increment", "decrement", "showMenu", "setValue"
    ]

    static func decode(_ json: String) -> WrenflowAccessibilitySnapshot? {
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(WrenflowAccessibilitySnapshot.self, from: data),
              validate(snapshot) else {
            return nil
        }
        return snapshot
    }

    private static func validate(_ snapshot: WrenflowAccessibilitySnapshot) -> Bool {
        guard snapshot.coordinateSpace == "windowContentTopLeft", !snapshot.nodes.isEmpty else {
            return false
        }
        let identifiers = Set(snapshot.nodes.map(\.id))
        guard identifiers.count == snapshot.nodes.count,
              snapshot.nodes.allSatisfy({ node in
                  !node.id.isEmpty && !node.label.isEmpty && roles.contains(node.role) &&
                      node.frame.isValid && Set(node.actions).isSubset(of: actions) &&
                      validateRoleMetadata(node) &&
                      node.parentID.map { identifiers.contains($0) && $0 != node.id } ?? true
              }),
              snapshot.focusedID.map(identifiers.contains) ?? true else {
            return false
        }

        let parents = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0.parentID) })
        for identifier in identifiers {
            var visited = Set<String>()
            var current: String? = identifier
            while let node = current {
                guard visited.insert(node).inserted else { return false }
                current = parents[node] ?? nil
            }
        }
        return true
    }

    private static func validateRoleMetadata(_ node: WrenflowAccessibilityNodeSnapshot) -> Bool {
        guard node.role == "slider" else { return true }
        guard let minimum = node.minimumValue,
              let maximum = node.maximumValue,
              let value = node.value.flatMap(Double.init),
              minimum.isFinite, maximum.isFinite, value.isFinite,
              minimum < maximum, (minimum ... maximum).contains(value) else {
            return false
        }
        return Set(["focus", "increment", "decrement", "setValue"]).isSubset(of: node.actions)
    }
}

private final class WrenflowAccessibilityElement: NSAccessibilityElement {
    let nodeID: String
    weak var bridge: WrenflowAccessibilityBridge?
    var supportedActions = Set<String>()
    var lastValue: String?
    var lastFocused = false
    private var applyingSnapshot = false

    init(nodeID: String, bridge: WrenflowAccessibilityBridge) {
        self.nodeID = nodeID
        self.bridge = bridge
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        perform("press")
    }

    override func accessibilityPerformIncrement() -> Bool {
        perform("increment")
    }

    override func accessibilityPerformDecrement() -> Bool {
        perform("decrement")
    }

    override func accessibilityPerformShowMenu() -> Bool {
        perform("showMenu")
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) {
            return isAccessibilityEnabled() && supportedActions.contains("press")
        }
        if selector == #selector(accessibilityPerformIncrement) {
            return isAccessibilityEnabled() && supportedActions.contains("increment")
        }
        if selector == #selector(accessibilityPerformDecrement) {
            return isAccessibilityEnabled() && supportedActions.contains("decrement")
        }
        if selector == #selector(accessibilityPerformShowMenu) {
            return isAccessibilityEnabled() && supportedActions.contains("showMenu")
        }
        if selector == #selector(setAccessibilityFocused(_:)) {
            return isAccessibilityEnabled() && supportedActions.contains("focus")
        }
        if selector == #selector(setAccessibilityValue(_:)) {
            return isAccessibilityEnabled() && supportedActions.contains("setValue")
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        if accessibilityFocused && !applyingSnapshot {
            _ = perform("focus")
        }
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        super.setAccessibilityValue(accessibilityValue)
        if !applyingSnapshot, supportedActions.contains("setValue") {
            _ = perform("setValue", value: accessibilityValue.map(String.init(describing:)))
        }
    }

    private func perform(_ action: String, value: String? = nil) -> Bool {
        guard isAccessibilityEnabled(), supportedActions.contains(action) else { return false }
        return bridge?.perform(id: nodeID, action: action, value: value) ?? false
    }

    func apply(_ snapshot: WrenflowAccessibilityNodeSnapshot, in contentView: NSView) {
        let previousValue = lastValue
        let previousFocused = lastFocused
        applyingSnapshot = true
        defer { applyingSnapshot = false }
        supportedActions = Set(snapshot.actions)
        lastValue = snapshot.value
        lastFocused = snapshot.focused

        setAccessibilityElement(true)
        setAccessibilityIdentifier(snapshot.id)
        let accessibilityRole = role(for: snapshot.role)
        setAccessibilityRole(accessibilityRole)
        setAccessibilityRoleDescription(accessibilityRole.description(with: nil))
        setAccessibilityLabel(snapshot.label)
        setAccessibilityEnabled(snapshot.enabled)
        setAccessibilityFocused(snapshot.focused)
        setAccessibilityValue(accessibilityValue(for: snapshot))
        setAccessibilityMinValue(snapshot.minimumValue.map { NSNumber(value: $0) })
        setAccessibilityMaxValue(snapshot.maximumValue.map { NSNumber(value: $0) })
        setAccessibilityModal(snapshot.role == "dialog")
        setAccessibilitySubrole(subrole(for: snapshot.role))

        let localFrame = NSRect(
            x: snapshot.frame.x,
            y: contentView.bounds.height - snapshot.frame.y - snapshot.frame.height,
            width: snapshot.frame.width,
            height: snapshot.frame.height
        )
        setAccessibilityFrame(NSAccessibility.screenRect(fromView: contentView, rect: localFrame))

        var customActions: [NSAccessibilityCustomAction] = []
        if supportedActions.contains("focus") {
            customActions.append(NSAccessibilityCustomAction(name: "Focus") { [weak self] in
                self?.perform("focus") ?? false
            })
        }
        setAccessibilityCustomActions(customActions)

        if previousValue != snapshot.value {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        if previousFocused != snapshot.focused && snapshot.focused {
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    private func role(for role: String) -> NSAccessibility.Role {
        switch role {
        case "button": return .button
        case "switch": return .checkBox
        case "textField": return .textField
        case "listBox": return .popUpButton
        case "slider": return .slider
        case "progressIndicator": return .progressIndicator
        case "heading": return NSAccessibility.Role(rawValue: "AXHeading")
        case "status", "staticText": return .staticText
        case "window", "dialog": return .window
        case "navigation": return .list
        case "group": return .group
        default: return .group
        }
    }

    private func subrole(for role: String) -> NSAccessibility.Subrole? {
        switch role {
        case "window": return .standardWindow
        case "dialog": return .dialog
        default: return nil
        }
    }

    private func accessibilityValue(for snapshot: WrenflowAccessibilityNodeSnapshot) -> Any? {
        guard let value = snapshot.value else { return nil }
        if snapshot.role == "switch" {
            return NSNumber(value: value == "true" || value == "on" || value == "1")
        }
        if ["slider", "progressIndicator"].contains(snapshot.role), let numericValue = Double(value) {
            return NSNumber(value: numericValue)
        }
        return value
    }
}

final class WrenflowAccessibilityBridge {
    typealias ActionHandler = (String) -> Void

    private let actionHandler: ActionHandler
    private weak var contentView: NSView?
    private var elements: [String: WrenflowAccessibilityElement] = [:]
    private var generation: UInt64?
    private var lastAnnouncementSerial: UInt64?

    init(actionHandler: @escaping ActionHandler) {
        self.actionHandler = actionHandler
    }

    var nodeCount: Int32 {
        Int32(clamping: elements.count)
    }

    static func validate(json: String) -> Bool {
        WrenflowAccessibilitySchema.decode(json) != nil
    }

    func attach(to window: NSWindow?) {
        guard let view = window?.contentView else { return }
        if contentView !== view {
            detach()
            contentView = view
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel("Wrenflow")
        }
    }

    func detach() {
        contentView?.setAccessibilityChildren(nil)
        contentView?.setAccessibilityChildrenInNavigationOrder(nil)
        contentView = nil
        elements.removeAll()
        generation = nil
        lastAnnouncementSerial = nil
    }

    func update(json: String, window: NSWindow?) -> Bool {
        guard let snapshot = WrenflowAccessibilitySchema.decode(json) else { return false }
        attach(to: window)
        guard let contentView else { return false }

        let identifiers = Set(snapshot.nodes.map(\.id))
        elements = elements.filter { identifiers.contains($0.key) }
        for node in snapshot.nodes where elements[node.id] == nil {
            elements[node.id] = WrenflowAccessibilityElement(nodeID: node.id, bridge: self)
        }
        let orderedNodes = snapshot.nodes.sorted { left, right in
            if left.parentID == right.parentID {
                return left.order < right.order
            }
            return left.order < right.order
        }
        for node in orderedNodes {
            elements[node.id]?.apply(node, in: contentView)
        }

        var childrenByParent: [String: [WrenflowAccessibilityElement]] = [:]
        var roots: [WrenflowAccessibilityElement] = []
        for node in snapshot.nodes {
            guard let element = elements[node.id] else { continue }
            if let parentID = node.parentID, let parent = elements[parentID] {
                element.setAccessibilityParent(parent)
                childrenByParent[parentID, default: []].append(element)
            } else {
                element.setAccessibilityParent(contentView)
                roots.append(element)
            }
        }
        for (identifier, element) in elements {
            let children = childrenByParent[identifier] ?? []
            element.setAccessibilityChildren(children)
        }
        contentView.setAccessibilityChildren(roots)

        if generation != snapshot.generation {
            generation = snapshot.generation
            NSAccessibility.post(element: contentView, notification: .layoutChanged)
        }
        if let announcement = snapshot.announcement,
           !announcement.message.isEmpty,
           lastAnnouncementSerial != announcement.serial {
            lastAnnouncementSerial = announcement.serial
            let priority: NSAccessibilityPriorityLevel = switch announcement.priority {
            case "high": .high
            case "low": .low
            default: .medium
            }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement.message,
                    .priority: priority.rawValue
                ]
            )
        }
        return true
    }

    fileprivate func perform(id: String, action: String, value: String?) -> Bool {
        let payload = WrenflowAccessibilityActionPayload(id: id, action: action, value: value)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        actionHandler(json)
        return true
    }
}
