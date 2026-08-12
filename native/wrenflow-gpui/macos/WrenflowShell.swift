import AppKit
import ApplicationServices
import AVFoundation
import Darwin
import ServiceManagement

public typealias WrenflowEventCallback = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
public typealias WrenflowDiagnosticCallback = @convention(c) (UInt8) -> Void

private var diagnosticCallback: WrenflowDiagnosticCallback?
private let diagnosticCallbackLock = NSLock()

private enum WrenflowDiagnosticFailure: UInt8 {
    case shellInstall = 1
    case loginItem = 2
    case uninstallEvidence = 3
    case bridgeDecode = 4
    case accessibility = 5
    case singleInstanceIdentity = 6
}

private func reportDiagnosticFailure(_ failure: WrenflowDiagnosticFailure) {
    let callback = diagnosticCallbackLock.withLock { diagnosticCallback }
    callback?(failure.rawValue)
}

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
    case accessibilityPreferencesChanged = 15
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

    private enum CodingKeys: String, CodingKey {
        case version
        case status
        case launchAtLogin
        case microphones
        case selectedMicrophoneID = "selectedMicrophoneId"
        case selectedHotkey
    }
}

private struct WrenflowPermissionsPayload: Encodable, Equatable {
    let microphone: String
    let accessibility: String

    var allGranted: Bool {
        microphone == "granted" && accessibility == "granted"
    }
}

private func permissionConfirmationTransition(
    remaining: Int,
    previousAllGranted: Bool?,
    currentAllGranted: Bool,
    force: Bool,
    detectLossTransition: Bool
) -> Int {
    if currentAllGranted {
        return 0
    }
    if detectLossTransition && previousAllGranted == true {
        return 2
    }
    if force && remaining > 0 {
        return remaining - 1
    }
    return remaining
}

// Fixed numeric test seam for the permission confirmation state machine. It
// exposes no permission payload or user data and production uses the same pure
// transition below.
@_cdecl("wrenflow_shell_permission_confirmation_transition")
public func wrenflowShellPermissionConfirmationTransition(
    _ remaining: Int32,
    _ previousAllGranted: Int32,
    _ currentAllGranted: Int32,
    _ force: Int32,
    _ detectLossTransition: Int32
) -> Int32 {
    let previous: Bool? = switch previousAllGranted {
    case 0: false
    case 1: true
    default: nil
    }
    return Int32(permissionConfirmationTransition(
        remaining: max(0, Int(remaining)),
        previousAllGranted: previous,
        currentAllGranted: currentAllGranted == 1,
        force: force == 1,
        detectLossTransition: detectLossTransition == 1
    ))
}

private struct WrenflowLaunchAtLoginPayload: Encodable {
    let isAvailable: Bool
    let enabled: Bool
    let isLoading: Bool
    let unavailableReason: String?
    let errorMessage: String?
}

private struct WrenflowAccessibilityPreferencesPayload: Encodable, Equatable {
    let increaseContrast: Bool
    let differentiateWithoutColor: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let textScalePercent: Int
}

private struct WrenflowUninstallEvidence: Encodable {
    let bundleIdentifier: String
    let bundlePath: String
    let pid: Int32
    let loginItemStatusBefore: String
    let loginItemStatusAfter: String
    let success: Bool
    let errorMessage: String?
}

private enum WrenflowWindowLayout: Int32 {
    case compact = 0
    case settings = 1

    var frameSize: NSSize {
        switch self {
        case .compact: return NSSize(width: 340, height: 380)
        case .settings: return NSSize(width: 720, height: 520)
        }
    }
}

/// Performance-only signed-process driver. Construction is reachable only
/// through the Rust two-gate performance request; ordinary launches never
/// provide its canonical ready/report paths.
private final class WrenflowPerformanceInteractionDriver {
    private struct Pulses: Encodable {
        let requested: Int
        let completed: Int
        let generationUptimeMs: [Double]
        let overlayMs: [Double]
        let pasteDispatchMs: [Double]
    }

    private struct HoldResult: Encodable {
        let requestedMs: Int
        let observedMs: Double
        let overlayMs: Double
        let pasteDispatchMs: Double
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let classification: String
        let source: String
        let keyCode: Int
        let pulses: Pulses
        let hold: HoldResult?
        let tccOrMicrophoneEvidence: Bool
        let passed: Bool
        let failureCode: String?
    }

    private enum Stage {
        case waitingForReady
        case pulse(Int)
        case hold
        case terminal
    }

    private static let pulseCount = 20
    private static let pulseHoldSeconds = 0.350
    private static let longHoldSeconds = 60.0
    private static let keyCode = 96

    private let readyURL: URL
    private let reportURL: URL
    private let onHotkeyPressed: () -> Void
    private let onHotkeyReleased: (TimeInterval) -> Void
    private let onTerminal: () -> Void
    private var stage = Stage.waitingForReady
    private var readyTimer: Timer?
    private var timeoutTimer: Timer?
    private var generatedAt: TimeInterval?
    private var requestedHoldSeconds: TimeInterval?
    private var observedOverlayMs: Double?
    private var observedPasteDispatchMs: Double?
    private var hotkeyReleased = false
    private var releaseScheduled = false
    private var generationUptimeMs: [Double] = []
    private var overlayMs: [Double] = []
    private var pasteDispatchMs: [Double] = []
    private var holdResult: HoldResult?
    private var observedHoldMs: Double?

    init(
        readyPath: String,
        reportPath: String,
        onHotkeyPressed: @escaping () -> Void,
        onHotkeyReleased: @escaping (TimeInterval) -> Void,
        onTerminal: @escaping () -> Void
    ) {
        readyURL = URL(fileURLWithPath: readyPath, isDirectory: false)
        reportURL = URL(fileURLWithPath: reportPath, isDirectory: false)
        self.onHotkeyPressed = onHotkeyPressed
        self.onHotkeyReleased = onHotkeyReleased
        self.onTerminal = onTerminal
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard readyURL.path.hasPrefix("/"), reportURL.path.hasPrefix("/") else {
            finishFailure("unsafe_interaction_path")
            return
        }
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.050, repeats: true) {
            [weak self] _ in self?.pollReady()
        }
        scheduleTimeout(after: 10 * 60, code: "interaction_ready_timeout")
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        cleanup()
        stage = .terminal
    }

    func observeOverlay(phase: WrenflowOverlayPhase) {
        dispatchPrecondition(condition: .onQueue(.main))
        // The warmed fixture pipeline may coalesce initializing/recording and
        // first expose transcribing to the GPUI snapshot poll. Every closed
        // phase renders the production lifecycle overlay; the first visible
        // one is the honest handler-ingress-to-overlay boundary.
        _ = phase
        guard observedOverlayMs == nil, let generatedAt else { return }
        observedOverlayMs = elapsedMilliseconds(since: generatedAt)
        scheduleReleaseAfterOverlay()
        completeCurrentInteractionIfReady()
    }

    func observePasteDispatch() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard hotkeyReleased, observedPasteDispatchMs == nil, let generatedAt else { return }
        observedPasteDispatchMs = elapsedMilliseconds(since: generatedAt)
        completeCurrentInteractionIfReady()
    }

    private func pollReady() {
        guard case .waitingForReady = stage else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: readyURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        readyTimer?.invalidate()
        readyTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.250) { [weak self] in
            guard let self, !self.isTerminal else { return }
            self.beginPulse(index: 0)
        }
    }

    private func beginPulse(index: Int) {
        stage = .pulse(index)
        beginInteraction(keyUpAfter: Self.pulseHoldSeconds)
    }

    private func beginLongHold() {
        stage = .hold
        beginInteraction(keyUpAfter: Self.longHoldSeconds)
    }

    private func beginInteraction(keyUpAfter holdSeconds: TimeInterval) {
        observedOverlayMs = nil
        observedPasteDispatchMs = nil
        hotkeyReleased = false
        releaseScheduled = false
        requestedHoldSeconds = holdSeconds
        let generated = ProcessInfo.processInfo.systemUptime
        generatedAt = generated
        if case .pulse = stage {
            generationUptimeMs.append(generated * 1_000)
        }
        // Deliberately begin after the real event-tap boundary. Physical
        // hotkeys and this two-gate driver enter the same typed shell callback;
        // the driver never posts or synthesizes an OS keyboard event.
        onHotkeyPressed()
        scheduleTimeout(after: holdSeconds + 30, code: "interaction_cycle_timeout")
    }

    private func scheduleReleaseAfterOverlay() {
        guard !releaseScheduled,
              !hotkeyReleased,
              let generatedAt,
              let requestedHoldSeconds else { return }
        releaseScheduled = true
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - generatedAt)
        let delay = max(0, requestedHoldSeconds - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.releaseHotkey(generatedAt: generatedAt)
        }
    }

    private func releaseHotkey(generatedAt: TimeInterval) {
        guard !isTerminal, !hotkeyReleased else { return }
        let observedSeconds = max(0, ProcessInfo.processInfo.systemUptime - generatedAt)
        onHotkeyReleased(observedSeconds)
        hotkeyReleased = true
        if case .hold = stage {
            let observed = observedSeconds * 1_000
            observedHoldMs = observed
            if observed < Self.longHoldSeconds * 1_000 {
                finishFailure("interaction_hold_too_short")
            }
        }
    }

    private func completeCurrentInteractionIfReady() {
        guard let overlay = observedOverlayMs, let pasteDispatch = observedPasteDispatchMs else {
            return
        }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        switch stage {
        case let .pulse(index):
            overlayMs.append(overlay)
            pasteDispatchMs.append(pasteDispatch)
            if index + 1 < Self.pulseCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.200) { [weak self] in
                    self?.beginPulse(index: index + 1)
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.200) { [weak self] in
                    self?.beginLongHold()
                }
            }
        case .hold:
            let observed = observedHoldMs ?? 0
            holdResult = HoldResult(
                requestedMs: Int(Self.longHoldSeconds * 1_000),
                observedMs: observed,
                overlayMs: overlay,
                pasteDispatchMs: pasteDispatch
            )
            finishSuccess()
        case .waitingForReady, .terminal:
            break
        }
    }

    private var isTerminal: Bool {
        if case .terminal = stage { return true }
        return false
    }

    private func scheduleTimeout(after seconds: TimeInterval, code: String) {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
            [weak self] _ in self?.finishFailure(code)
        }
    }

    private func finishSuccess() {
        guard overlayMs.count == Self.pulseCount,
              pasteDispatchMs.count == Self.pulseCount,
              generationUptimeMs.count == Self.pulseCount,
              holdResult != nil else {
            finishFailure("interaction_incomplete")
            return
        }
        publish(passed: true, failureCode: nil)
    }

    private func finishFailure(_ code: String) {
        guard !isTerminal else { return }
        publish(passed: false, failureCode: code)
    }

    private func publish(passed: Bool, failureCode: String?) {
        stage = .terminal
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        readyTimer?.invalidate()
        readyTimer = nil
        let report = Report(
            schemaVersion: 1,
            classification: "post_event_tap_synthetic",
            source: "signed_wrenflow_typed_hotkey_callback",
            keyCode: Self.keyCode,
            pulses: Pulses(
                requested: Self.pulseCount,
                completed: overlayMs.count,
                generationUptimeMs: generationUptimeMs,
                overlayMs: overlayMs,
                pasteDispatchMs: pasteDispatchMs
            ),
            hold: holdResult,
            tccOrMicrophoneEvidence: false,
            passed: passed,
            failureCode: failureCode
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: reportURL, options: .atomic)
            if let file = try? FileHandle(forWritingTo: reportURL) {
                try? file.synchronize()
                try? file.close()
            }
        }
        cleanup()
        onTerminal()
    }

    private func cleanup() {
        readyTimer?.invalidate()
        readyTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        if !hotkeyReleased, let generatedAt {
            onHotkeyReleased(max(0, ProcessInfo.processInfo.systemUptime - generatedAt))
            hotkeyReleased = true
        }
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }
}

private final class WrenflowShell: NSObject, NSMenuDelegate {
    static let shared = WrenflowShell()

    private static let permissionFallbackInterval: TimeInterval = 60
    private static let permissionConfirmationInterval: TimeInterval = 0.25

    private var callback: WrenflowEventCallback?
    private var windowTitle = "Wrenflow"
    private var version = ""
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var permissionConfirmationsRemaining = 0
    private var lastPermissions: WrenflowPermissionsPayload?
    private var lastAccessibilityPreferences: WrenflowAccessibilityPreferencesPayload?
    private var observesWorkspace = false
    private var pendingReopen = false
    private var pendingQuit = false
    private var showSettingsSignal: DispatchSourceSignal?
    private var quitSignal: DispatchSourceSignal?
    private var selectedHotkey: UInt16 = 63
    private var performanceInteraction: WrenflowPerformanceInteractionDriver?
    private lazy var hotkey = WrenflowHotkeyMonitor(
        onPressed: { [weak self] in self?.handleHotkeyPressed() },
        onReleased: { [weak self] duration in self?.handleHotkeyReleased(duration) }
    )
    private lazy var overlays = WrenflowOverlayController { [weak self] actionID in
        self?.emit(.overlayAction, payload: actionID)
    }
    private lazy var accessibility = WrenflowAccessibilityBridge { [weak self] payload in
        self?.emit(.accessibilityAction, payload: payload)
    }

    func install(windowTitle: String, version: String, callback: WrenflowEventCallback?) -> Int32 {
        dispatchPrecondition(condition: .onQueue(.main))
        shutdown(removeReopenObservation: false)

        self.callback = callback
        self.windowTitle = windowTitle
        self.version = version
        disableWindowRestoration()

        if let evidencePath = prepareUninstallEvidencePath() {
            prepareForUninstall(evidencePath: evidencePath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.emit(.quitRequested)
            }
            return 0
        }

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        observesWorkspace = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Wrenflow") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "W"
        }
        item.button?.toolTip = "Wrenflow"
        statusItem = item

        guard setAccessoryPolicy() else {
            reportDiagnosticFailure(.shellInstall)
            shutdown(removeReopenObservation: false)
            return -3
        }
        attachCloseButton()
        accessibility.attach(to: settingsWindow)
        refreshPermissions(force: true, detectLossTransition: true)
        emitAccessibilityPreferences(force: true)
        emitLaunchAtLogin(errorMessage: nil)
        if pendingReopen {
            pendingReopen = false
            emit(.openSettings)
        }
        if pendingQuit {
            pendingQuit = false
            emit(.quitRequested)
        }
        return 0
    }

    func shutdown(removeReopenObservation: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        performanceInteraction?.cancel()
        performanceInteraction = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionConfirmationsRemaining = 0
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        if observesWorkspace {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            observesWorkspace = false
        }
        if removeReopenObservation {
            pendingReopen = false
            pendingQuit = false
            showSettingsSignal?.cancel()
            showSettingsSignal = nil
            quitSignal?.cancel()
            quitSignal = nil
            _ = Darwin.signal(SIGUSR2, SIG_DFL)
            _ = Darwin.signal(SIGUSR1, SIG_DFL)
        }
        hotkey.stop()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        overlays.shutdown()
        accessibility.detach()
        callback = nil
        lastPermissions = nil
        lastAccessibilityPreferences = nil
    }

    func updateTray(json: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let data = json.data(using: .utf8),
              let presentation = try? JSONDecoder().decode(WrenflowTrayPresentation.self, from: data) else {
            reportDiagnosticFailure(.bridgeDecode)
            return false
        }
        updateTray(presentation)
        return true
    }

    func updateAccessibility(json: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let updated = accessibility.update(json: json, window: settingsWindow)
        if !updated {
            reportDiagnosticFailure(.accessibility)
        }
        return updated
    }

    static func claimSingleInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: "me.gulya.wrenflow")
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard !running.isEmpty else {
            return true
        }
        guard running.count == 1,
              let existing = running.first,
              existing.bundleURL?.resolvingSymlinksInPath().standardizedFileURL
                == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL,
              existing.executableURL?.resolvingSymlinksInPath().standardizedFileURL
                == Bundle.main.executableURL?.resolvingSymlinksInPath().standardizedFileURL else {
            // A same-ID process from another path (or an ambiguous duplicate
            // set) is not trusted. The new process exits without signalling it.
            reportDiagnosticFailure(.singleInstanceIdentity)
            return false
        }
        if ProcessInfo.processInfo.arguments.contains("--lifecycle-request-quit") {
            _ = Darwin.kill(existing.processIdentifier, SIGUSR1)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            return false
        }
        _ = Darwin.kill(existing.processIdentifier, SIGUSR2)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        return false
    }

    func installProcessSignals() {
        guard showSettingsSignal == nil else { return }
        _ = Darwin.signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler { [weak self] in self?.handleApplicationReopen() }
        showSettingsSignal = source
        source.resume()

        _ = Darwin.signal(SIGUSR1, SIG_IGN)
        let quitSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        quitSource.setEventHandler { [weak self] in self?.handleQuitSignal() }
        quitSignal = quitSource
        quitSource.resume()
    }

    private func handleApplicationReopen() {
        if callback == nil {
            pendingReopen = true
        } else {
            emit(.openSettings)
        }
    }

    private func handleQuitSignal() {
        if callback == nil {
            pendingQuit = true
        } else {
            emit(.quitRequested)
        }
    }


    var accessibilityNodeCount: Int32 {
        accessibility.nodeCount
    }

    func showMainWindow() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let settingsWindow else { return false }
        guard applyActivationPolicy(.regular) else { return false }
        disableWindowRestoration()
        attachCloseButton()
        accessibility.attach(to: settingsWindow)
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissions(force: false, detectLossTransition: true)
        return true
    }

    func hideMainWindow() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        settingsWindow?.close()
        let policyApplied = setAccessoryPolicy()
        emit(.mainWindowHidden)
        return policyApplied
    }

    func ensureAccessoryPolicy() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return setAccessoryPolicy()
    }

    func applyWindowLayout(_ rawValue: Int32) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let layout = WrenflowWindowLayout(rawValue: rawValue),
              let window = settingsWindow else { return false }
        disableWindowRestoration(for: window)
        var frame = window.frame
        frame.size = layout.frameSize
        window.minSize = NSSize(width: 300, height: 340)
        window.setFrame(frame, display: true)
        window.center()
        return true
    }

    func applyThemePreference(_ rawValue: Int32) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let appearance: NSAppearance?
        switch rawValue {
        case 0:
            appearance = nil
        case 1:
            appearance = NSAppearance(named: .aqua)
        case 2:
            appearance = NSAppearance(named: .darkAqua)
        default:
            return false
        }

        // This is deliberately app-local. `nil` resumes the live system
        // appearance; Aqua/Dark Aqua override only this Wrenflow process and
        // never mutate the user's System Settings.
        NSApp.appearance = appearance
        settingsWindow?.appearance = appearance
        settingsWindow?.contentView?.needsDisplay = true
        settingsWindow?.invalidateShadow()
        return true
    }

    func requestMicrophonePermission() {
        dispatchPrecondition(condition: .onQueue(.main))
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissions(force: true, detectLossTransition: true)
            }
        }
    }

    func requestAccessibilityPermission() {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refreshPermissions(force: true, detectLossTransition: true)
    }

    func openPermissionSettings(kind: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        let pane = kind == 0 ? "Privacy_Microphone" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let matchesRequest = enabled
                ? SMAppService.mainApp.status == .enabled
                : !Self.isRegisteredLoginItemStatus(SMAppService.mainApp.status)
            let error = matchesRequest ? nil : "macOS did not apply the requested login item state"
            emitLaunchAtLogin(errorMessage: error)
            if !matchesRequest {
                reportDiagnosticFailure(.loginItem)
            }
            return matchesRequest
        } catch {
            reportDiagnosticFailure(.loginItem)
            emitLaunchAtLogin(errorMessage: error.localizedDescription)
            return false
        }
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
        performanceInteraction?.observeOverlay(phase: resolved)
        overlays.show(phase: resolved, audioLevel: audioLevel)
    }

    func startPerformanceInteraction(readyPath: String, reportPath: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard performanceInteraction == nil else { return false }
        let driver = WrenflowPerformanceInteractionDriver(
            readyPath: readyPath,
            reportPath: reportPath,
            onHotkeyPressed: { [weak self] in self?.handleHotkeyPressed() },
            onHotkeyReleased: { [weak self] duration in
                self?.handleHotkeyReleased(duration)
            },
            onTerminal: { [weak self] in
                self?.performanceInteraction = nil
            }
        )
        performanceInteraction = driver
        driver.start()
        return true
    }

    func observePerformancePasteDispatch() {
        dispatchPrecondition(condition: .onQueue(.main))
        performanceInteraction?.observePasteDispatch()
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

    /// GPUI 0.2.2 takes a non-recursive platform mutex while AppKit reports
    /// key-window changes. AppKit persistent UI restoration can synchronously
    /// order and resign the same GPUI window, re-entering that callback and
    /// deadlocking launch. Wrenflow owns route/window restoration in AppModel,
    /// so the native window must never participate in AppKit restoration.
    private func disableWindowRestoration() {
        guard let window = settingsWindow else { return }
        disableWindowRestoration(for: window)
    }

    private func disableWindowRestoration(for window: NSWindow) {
        window.isRestorable = false
        window.restorationClass = nil
        window.disableSnapshotRestoration()
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private static func isRegisteredLoginItemStatus(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private static func loginItemStatusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    private func prepareUninstallEvidencePath() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--prepare-uninstall-evidence") else {
            return nil
        }
        guard arguments.indices.contains(flag + 1) else {
            reportDiagnosticFailure(.uninstallEvidence)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        }
        return arguments[flag + 1]
    }

    private func prepareForUninstall(evidencePath: String) {
        let evidenceURL = URL(fileURLWithPath: evidencePath).standardizedFileURL
        let parent = evidenceURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        let validParent = parent.deletingLastPathComponent() == temporaryRoot
            && parent.lastPathComponent.hasPrefix("wrenflow-uninstall.")
        guard evidenceURL.lastPathComponent == "wrenflow-uninstall-evidence.json", validParent else {
            reportDiagnosticFailure(.uninstallEvidence)
            return
        }

        let service = SMAppService.mainApp
        let before = service.status
        var operationError: String?
        if Self.isRegisteredLoginItemStatus(before) {
            do {
                try service.unregister()
            } catch {
                reportDiagnosticFailure(.uninstallEvidence)
                operationError = error.localizedDescription
            }
        }
        let after = service.status
        let success = !Self.isRegisteredLoginItemStatus(after) && operationError == nil
        let evidence = WrenflowUninstallEvidence(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundlePath,
            pid: ProcessInfo.processInfo.processIdentifier,
            loginItemStatusBefore: Self.loginItemStatusName(before),
            loginItemStatusAfter: Self.loginItemStatusName(after),
            success: success,
            errorMessage: operationError
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(evidence)
            try data.write(to: evidenceURL, options: .atomic)
        } catch {
            reportDiagnosticFailure(.uninstallEvidence)
        }
    }

    private func attachCloseButton() {
        guard let button = settingsWindow?.standardWindowButton(.closeButton) else { return }
        button.target = self
        button.action = #selector(closeMainWindow)
    }

    private func setAccessoryPolicy() -> Bool {
        applyActivationPolicy(.accessory)
    }

    private func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        if NSApp.activationPolicy() == policy { return true }
        return NSApp.setActivationPolicy(policy) && NSApp.activationPolicy() == policy
    }

    private func updateTray(_ presentation: WrenflowTrayPresentation) {
        selectedHotkey = presentation.selectedHotkey
        hotkey.setTargetKeyCode(selectedHotkey)
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

        menu.addItem(.separator())
        addMenuItem(menu, title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        addMenuItem(menu, title: "History", action: #selector(openHistory), keyEquivalent: "")
        addMenuItem(menu, title: "About Wrenflow", action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(.separator())
        addMenuItem(menu, title: "Quit Wrenflow", action: #selector(quit), keyEquivalent: "q")
        menu.delegate = self
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

    private func handleHotkeyPressed() {
        emit(.hotkeyPressed)
    }

    private func handleHotkeyReleased(_ duration: TimeInterval) {
        emit(.hotkeyReleased, payload: String(duration * 1_000))
    }

    private func permissionsPayload() -> WrenflowPermissionsPayload {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "granted"
        case .denied: microphone = "denied"
        case .restricted: microphone = "restricted"
        case .notDetermined: microphone = "unknown"
        @unknown default: microphone = "unknown"
        }
        return WrenflowPermissionsPayload(
            microphone: microphone,
            accessibility: AXIsProcessTrusted() ? "granted" : "denied"
        )
    }

    private func refreshPermissions(force: Bool, detectLossTransition: Bool) {
        if hotkey.isRunning == false {
            _ = hotkey.start()
        }
        let payload = permissionsPayload()
        let previous = lastPermissions
        // Runtime recovery deliberately requires three consecutive loss
        // observations. The first changed payload plus exactly two fresh,
        // forced queries confirms stable revocation without a permanent
        // high-frequency timer. The budget is consumed only after a forced
        // query executes, so intervening lifecycle refreshes cannot lose one.
        permissionConfirmationsRemaining = permissionConfirmationTransition(
            remaining: permissionConfirmationsRemaining,
            previousAllGranted: previous?.allGranted,
            currentAllGranted: payload.allGranted,
            force: force,
            detectLossTransition: detectLossTransition
        )
        if force || payload != lastPermissions {
            lastPermissions = payload
            emitJSON(.permissionsChanged, value: payload)
        }
        schedulePermissionRefresh()
    }

    private func schedulePermissionRefresh() {
        permissionTimer?.invalidate()
        let confirmation = permissionConfirmationsRemaining > 0
        let interval = confirmation
            ? Self.permissionConfirmationInterval
            : Self.permissionFallbackInterval
        permissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            self?.refreshPermissions(
                force: confirmation,
                detectLossTransition: !confirmation
            )
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissions(force: false, detectLossTransition: true)
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

    private func emitAccessibilityPreferences(force: Bool) {
        let workspace = NSWorkspace.shared
        let preferredBodySize = NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize
        let rawTextScalePercent = Int((preferredBodySize / NSFont.systemFontSize * 100).rounded())
        let textScalePercent = min(200, max(100, rawTextScalePercent))
        let payload = WrenflowAccessibilityPreferencesPayload(
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            textScalePercent: textScalePercent
        )
        guard force || payload != lastAccessibilityPreferences else { return }
        lastAccessibilityPreferences = payload
        emitJSON(.accessibilityPreferencesChanged, value: payload)
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        hotkey.stop()
        overlays.hide()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        hotkey.stop()
        refreshPermissions(force: true, detectLossTransition: true)
        emitLaunchAtLogin(errorMessage: nil)
        emitAccessibilityPreferences(force: true)
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissions(force: false, detectLossTransition: true)
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        emitAccessibilityPreferences(force: false)
    }

    private func emitJSON<T: Encodable>(_ event: WrenflowShellEvent, value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            reportDiagnosticFailure(.bridgeDecode)
            return
        }
        emit(event, payload: json)
    }

    @objc private func openSettings() {
        emit(.openSettings)
    }

    @objc private func openHistory() {
        emit(.openHistory)
    }

    @objc private func openAbout() {
        emit(.openAbout)
    }
    @objc private func quit() { emit(.quitRequested) }

    @objc private func closeMainWindow() {
        if !hideMainWindow() {
            reportDiagnosticFailure(.shellInstall)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        setLaunchAtLogin(sender.state != .on)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            emit(.selectMicrophone, payload: id)
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

@_cdecl("wrenflow_shell_set_diagnostic_callback")
public func wrenflowShellSetDiagnosticCallback(_ callback: WrenflowDiagnosticCallback?) {
    diagnosticCallbackLock.withLock { diagnosticCallback = callback }
}

@_cdecl("wrenflow_shell_prepare_process")
public func wrenflowShellPrepareProcess() {
    // This runs on the process main thread before GPUI constructs NSApplication.
    // Wrenflow restores its route from AppModel and intentionally never restores
    // AppKit windows, so stale UI records must not enter AppKit restoration.
    dispatchPrecondition(condition: .onQueue(.main))
    UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    WrenflowShell.shared.installProcessSignals()
}

@_cdecl("wrenflow_shell_install")
public func wrenflowShellInstall(
    _ title: UnsafePointer<CChar>?,
    _ version: UnsafePointer<CChar>?,
    _ callback: WrenflowEventCallback?
) -> Int32 {
    guard let title = string(title), let version = string(version) else {
        reportDiagnosticFailure(.shellInstall)
        return -1
    }
    return onMain {
        WrenflowShell.shared.install(windowTitle: title, version: version, callback: callback)
    }
}

@_cdecl("wrenflow_shell_claim_single_instance")
public func wrenflowShellClaimSingleInstance() -> Int32 {
    onMain { WrenflowShell.claimSingleInstance() ? 0 : 1 }
}

@_cdecl("wrenflow_shell_shutdown")
public func wrenflowShellShutdown() {
    onMain { WrenflowShell.shared.shutdown() }
}

@_cdecl("wrenflow_shell_show_main_window")
public func wrenflowShellShowMainWindow() -> Int32 {
    onMain { WrenflowShell.shared.showMainWindow() ? 0 : -1 }
}

@_cdecl("wrenflow_shell_hide_main_window")
public func wrenflowShellHideMainWindow() -> Int32 {
    onMain { WrenflowShell.shared.hideMainWindow() ? 0 : -1 }
}

@_cdecl("wrenflow_shell_ensure_accessory_policy")
public func wrenflowShellEnsureAccessoryPolicy() -> Int32 {
    onMain { WrenflowShell.shared.ensureAccessoryPolicy() ? 0 : -1 }
}

@_cdecl("wrenflow_shell_apply_window_layout")
public func wrenflowShellApplyWindowLayout(_ layout: Int32) -> Int32 {
    onMain { WrenflowShell.shared.applyWindowLayout(layout) ? 0 : -1 }
}

@_cdecl("wrenflow_shell_apply_theme_preference")
public func wrenflowShellApplyThemePreference(_ preference: Int32) -> Int32 {
    onMain { WrenflowShell.shared.applyThemePreference(preference) ? 0 : -1 }
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

@_cdecl("wrenflow_shell_start_performance_interaction")
public func wrenflowShellStartPerformanceInteraction(
    _ readyPath: UnsafePointer<CChar>?,
    _ reportPath: UnsafePointer<CChar>?
) -> Int32 {
    guard let readyPath = string(readyPath), let reportPath = string(reportPath) else {
        return -1
    }
    return onMain {
        WrenflowShell.shared.startPerformanceInteraction(
            readyPath: readyPath,
            reportPath: reportPath
        ) ? 0 : -2
    }
}

@_cdecl("wrenflow_shell_observe_performance_paste_dispatch")
public func wrenflowShellObservePerformancePasteDispatch() {
    onMain { WrenflowShell.shared.observePerformancePasteDispatch() }
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
public func wrenflowShellSetLaunchAtLogin(_ enabled: Bool) -> Int32 {
    onMain { WrenflowShell.shared.setLaunchAtLogin(enabled) ? 0 : -1 }
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
