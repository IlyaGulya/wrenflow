import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

public typealias WrenflowEventCallback = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

private enum WrenflowShellEvent: Int32 {
    case openSettings = 1
    case openHistory = 2
    case openAbout = 3
    case selectMicrophone = 4
    case quitRequested = 6
    case overlayAction = 7
    case permissionsChanged = 8
    case launchAtLoginChanged = 9
    case mainWindowHidden = 10
    case hotkeyPressed = 12
    case hotkeyReleased = 13
    case accessibilityAction = 14
}

private struct WrenflowTrayPresentation: Decodable {
    struct Microphone: Decodable {
        let id: String
        let name: String
    }

    let version: String
    let status: String
    let launchAtLogin: Bool
    let microphones: [Microphone]
    let selectedMicrophoneID: String
    let selectedHotkey: UInt16
    let updateURL: String?
}

private struct WrenflowPermissionsPayload: Encodable, Equatable {
    let microphone: String
    let accessibility: String
}

private struct WrenflowLaunchAtLoginPayload: Encodable {
    let isAvailable: Bool
    let enabled: Bool
    let isLoading: Bool
    let unavailableReason: String?
    let errorMessage: String?
}

private final class WrenflowShell: NSObject {
    static let shared = WrenflowShell()

    private var callback: WrenflowEventCallback?
    private var windowTitle = "Wrenflow"
    private var version = ""
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var lastPermissions: WrenflowPermissionsPayload?
    private lazy var hotkey = WrenflowHotkeyMonitor(
        onPressed: { [weak self] in self?.emit(.hotkeyPressed) },
        onReleased: { [weak self] duration in
            let milliseconds = duration * 1_000
            self?.emit(.hotkeyReleased, payload: String(milliseconds))
        }
    )
    private lazy var overlays = WrenflowOverlayController { [weak self] actionID in
        self?.emit(.overlayAction, payload: actionID)
    }
    private lazy var accessibility = WrenflowAccessibilityBridge { [weak self] payload in
        self?.emit(.accessibilityAction, payload: payload)
    }

    func install(windowTitle: String, version: String, callback: WrenflowEventCallback?) {
        dispatchPrecondition(condition: .onQueue(.main))
        shutdown()
        self.callback = callback
        self.windowTitle = windowTitle
        self.version = version

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Wrenflow") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "W"
        }
        item.button?.toolTip = "Wrenflow"
        statusItem = item
        updateTray(WrenflowTrayPresentation(
            version: version,
            status: "Ready",
            launchAtLogin: launchAtLoginEnabled,
            microphones: [],
            selectedMicrophoneID: "default",
            selectedHotkey: 63,
            updateURL: nil
        ))

        setAccessoryPolicy()
        attachCloseButton()
        accessibility.attach(to: settingsWindow)
        emitPermissions(force: true)
        emitLaunchAtLogin(errorMessage: nil)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if self?.hotkey.isRunning == false {
                _ = self?.hotkey.start()
            }
            self?.emitPermissions(force: false)
        }
    }

    func shutdown() {
        dispatchPrecondition(condition: .onQueue(.main))
        permissionTimer?.invalidate()
        permissionTimer = nil
        hotkey.stop()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        overlays.shutdown()
        accessibility.detach()
        callback = nil
        lastPermissions = nil
    }

    func updateTray(json: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let data = json.data(using: .utf8),
              let presentation = try? JSONDecoder().decode(WrenflowTrayPresentation.self, from: data) else {
            return false
        }
        updateTray(presentation)
        return true
    }

    func updateAccessibility(json: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return accessibility.update(json: json, window: settingsWindow)
    }

    var accessibilityNodeCount: Int32 {
        accessibility.nodeCount
    }

    func showMainWindow() {
        dispatchPrecondition(condition: .onQueue(.main))
        NSApp.setActivationPolicy(.regular)
        attachCloseButton()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideMainWindow() {
        dispatchPrecondition(condition: .onQueue(.main))
        settingsWindow?.orderOut(nil)
        setAccessoryPolicy()
        emit(.mainWindowHidden)
    }

    func requestMicrophonePermission() {
        dispatchPrecondition(condition: .onQueue(.main))
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.emitPermissions(force: true) }
        }
    }

    func requestAccessibilityPermission() {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        emitPermissions(force: true)
    }

    func openPermissionSettings(kind: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        let pane = kind == 0 ? "Privacy_Microphone" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            emitLaunchAtLogin(errorMessage: nil)
        } catch {
            emitLaunchAtLogin(errorMessage: error.localizedDescription)
        }
    }

    func openURL(_ value: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let url = URL(string: value) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func showOverlay(phase: Int32, audioLevel: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        let resolved: WrenflowOverlayPhase
        switch phase {
        case 0: resolved = .initializing
        case 1: resolved = .recording
        case 2: resolved = .transcribing
        default:
            overlays.hide()
            return
        }
        overlays.show(phase: resolved, audioLevel: audioLevel)
    }

    func updateOverlayAudioLevel(_ level: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        overlays.updateAudioLevel(level)
    }

    func hideOverlay() {
        dispatchPrecondition(condition: .onQueue(.main))
        overlays.hide()
    }

    func showError(message: String, actionLabel: String?, actionID: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        overlays.showError(message: message, actionLabel: actionLabel, actionID: actionID)
    }

    private var settingsWindow: NSWindow? {
        NSApp.windows.first { window in
            !(window is NSPanel) && window.title == windowTitle
        }
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func attachCloseButton() {
        guard let button = settingsWindow?.standardWindowButton(.closeButton) else { return }
        button.target = self
        button.action = #selector(closeMainWindow)
    }

    private func setAccessoryPolicy() {
        settingsWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    private func updateTray(_ presentation: WrenflowTrayPresentation) {
        hotkey.setTargetKeyCode(presentation.selectedHotkey)
        _ = hotkey.start()
        let menu = NSMenu()
        menu.autoenablesItems = false

        let versionItem = NSMenuItem(title: "Wrenflow \(presentation.version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let status = NSMenuItem(title: presentation.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = presentation.launchAtLogin ? .on : .off
        menu.addItem(launch)

        if !presentation.microphones.isEmpty {
            let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
            let microphoneMenu = NSMenu()
            for microphone in presentation.microphones {
                let item = NSMenuItem(
                    title: microphone.name,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone.id
                item.state = microphone.id == presentation.selectedMicrophoneID ? .on : .off
                microphoneMenu.addItem(item)
            }
            microphoneItem.submenu = microphoneMenu
            menu.addItem(microphoneItem)
        }

        if let updateURL = presentation.updateURL {
            let update = NSMenuItem(
                title: "Open Update Page…",
                action: #selector(openUpdatePage(_:)),
                keyEquivalent: ""
            )
            update.target = self
            update.representedObject = updateURL
            menu.addItem(update)
        }

        menu.addItem(.separator())
        addMenuItem(menu, title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        addMenuItem(menu, title: "History", action: #selector(openHistory), keyEquivalent: "")
        addMenuItem(menu, title: "About Wrenflow", action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(.separator())
        addMenuItem(menu, title: "Quit Wrenflow", action: #selector(quit), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    private func addMenuItem(_ menu: NSMenu, title: String, action: Selector, keyEquivalent: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private func emit(_ event: WrenflowShellEvent, payload: String? = nil) {
        guard let callback else { return }
        guard let payload else {
            callback(event.rawValue, nil)
            return
        }
        payload.withCString { pointer in callback(event.rawValue, pointer) }
    }

    private func emitPermissions(force: Bool) {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "granted"
        case .denied: microphone = "denied"
        case .restricted: microphone = "restricted"
        case .notDetermined: microphone = "unknown"
        @unknown default: microphone = "unknown"
        }
        let payload = WrenflowPermissionsPayload(
            microphone: microphone,
            accessibility: AXIsProcessTrusted() ? "granted" : "denied"
        )
        guard force || payload != lastPermissions else { return }
        lastPermissions = payload
        emitJSON(.permissionsChanged, value: payload)
    }

    private func emitLaunchAtLogin(errorMessage: String?) {
        emitJSON(
            .launchAtLoginChanged,
            value: WrenflowLaunchAtLoginPayload(
                isAvailable: true,
                enabled: launchAtLoginEnabled,
                isLoading: false,
                unavailableReason: nil,
                errorMessage: errorMessage
            )
        )
    }

    private func emitJSON<T: Encodable>(_ event: WrenflowShellEvent, value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        emit(event, payload: json)
    }

    @objc private func openSettings() {
        showMainWindow()
        emit(.openSettings)
    }

    @objc private func openHistory() {
        showMainWindow()
        emit(.openHistory)
    }

    @objc private func openAbout() {
        showMainWindow()
        emit(.openAbout)
    }
    @objc private func quit() { emit(.quitRequested) }

    @objc private func closeMainWindow() { hideMainWindow() }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        setLaunchAtLogin(sender.state != .on)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            emit(.selectMicrophone, payload: id)
        }
    }

    @objc private func openUpdatePage(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String {
            _ = openURL(value)
        }
    }
}

private func onMain<T>(_ operation: () -> T) -> T {
    if Thread.isMainThread {
        return operation()
    }
    return DispatchQueue.main.sync(execute: operation)
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map(String.init(cString:))
}

@_cdecl("wrenflow_shell_install")
public func wrenflowShellInstall(
    _ title: UnsafePointer<CChar>?,
    _ version: UnsafePointer<CChar>?,
    _ callback: WrenflowEventCallback?
) -> Int32 {
    guard let title = string(title), let version = string(version) else { return -1 }
    onMain { WrenflowShell.shared.install(windowTitle: title, version: version, callback: callback) }
    return 0
}

@_cdecl("wrenflow_shell_shutdown")
public func wrenflowShellShutdown() {
    onMain { WrenflowShell.shared.shutdown() }
}

@_cdecl("wrenflow_shell_show_main_window")
public func wrenflowShellShowMainWindow() {
    onMain { WrenflowShell.shared.showMainWindow() }
}

@_cdecl("wrenflow_shell_hide_main_window")
public func wrenflowShellHideMainWindow() {
    onMain { WrenflowShell.shared.hideMainWindow() }
}

@_cdecl("wrenflow_shell_update_tray")
public func wrenflowShellUpdateTray(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let json = string(json) else { return -1 }
    return onMain { WrenflowShell.shared.updateTray(json: json) ? 0 : -2 }
}

@_cdecl("wrenflow_shell_update_accessibility")
public func wrenflowShellUpdateAccessibility(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let json = string(json) else { return -1 }
    return onMain { WrenflowShell.shared.updateAccessibility(json: json) ? 0 : -2 }
}

@_cdecl("wrenflow_shell_accessibility_node_count")
public func wrenflowShellAccessibilityNodeCount() -> Int32 {
    onMain { WrenflowShell.shared.accessibilityNodeCount }
}

@_cdecl("wrenflow_accessibility_validate_snapshot")
public func wrenflowAccessibilityValidateSnapshot(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let json = string(json) else { return -1 }
    return WrenflowAccessibilityBridge.validate(json: json) ? 0 : -2
}

@_cdecl("wrenflow_shell_request_microphone")
public func wrenflowShellRequestMicrophone() {
    onMain { WrenflowShell.shared.requestMicrophonePermission() }
}

@_cdecl("wrenflow_shell_request_accessibility")
public func wrenflowShellRequestAccessibility() {
    onMain { WrenflowShell.shared.requestAccessibilityPermission() }
}

@_cdecl("wrenflow_shell_open_permission_settings")
public func wrenflowShellOpenPermissionSettings(_ kind: Int32) {
    onMain { WrenflowShell.shared.openPermissionSettings(kind: kind) }
}

@_cdecl("wrenflow_shell_set_launch_at_login")
public func wrenflowShellSetLaunchAtLogin(_ enabled: Bool) {
    onMain { WrenflowShell.shared.setLaunchAtLogin(enabled) }
}

@_cdecl("wrenflow_shell_open_url")
public func wrenflowShellOpenURL(_ value: UnsafePointer<CChar>?) -> Int32 {
    guard let value = string(value) else { return -1 }
    return onMain { WrenflowShell.shared.openURL(value) ? 0 : -2 }
}

@_cdecl("wrenflow_shell_show_overlay")
public func wrenflowShellShowOverlay(_ phase: Int32, _ audioLevel: Float) {
    onMain { WrenflowShell.shared.showOverlay(phase: phase, audioLevel: audioLevel) }
}

@_cdecl("wrenflow_shell_update_overlay_audio")
public func wrenflowShellUpdateOverlayAudio(_ audioLevel: Float) {
    onMain { WrenflowShell.shared.updateOverlayAudioLevel(audioLevel) }
}

@_cdecl("wrenflow_shell_hide_overlay")
public func wrenflowShellHideOverlay() {
    onMain { WrenflowShell.shared.hideOverlay() }
}

@_cdecl("wrenflow_shell_show_error")
public func wrenflowShellShowError(
    _ message: UnsafePointer<CChar>?,
    _ actionLabel: UnsafePointer<CChar>?,
    _ actionID: UnsafePointer<CChar>?
) -> Int32 {
    guard let message = string(message) else { return -1 }
    onMain {
        WrenflowShell.shared.showError(
            message: message,
            actionLabel: string(actionLabel),
            actionID: string(actionID)
        )
    }
    return 0
}

@_cdecl("wrenflow_shell_terminate")
public func wrenflowShellTerminate() {
    onMain { NSApp.terminate(nil) }
}
