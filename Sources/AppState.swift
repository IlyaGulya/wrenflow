import Foundation
import Combine
import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import os.log

private let recordingLog = OSLog(subsystem: "me.gulya.wrenflow", category: "Recording")

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case aiCleanup
    case runLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .aiCleanup: return "AI Cleanup"
        case .runLog: return "Run Log"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .models: return "cpu"
        case .aiCleanup: return "sparkles"
        case .runLog: return "list.bullet"
        }
    }
}

enum SwiftPipelineState: Equatable {
    case idle
    case starting                              // permissions ok, engine spinning up
    case initializing                          // >0.5s elapsed, dots overlay shown
    case recording                             // first audio buffer arrived, waveform
    case transcribing(showingIndicator: Bool)   // STT running
    case postProcessing(showingIndicator: Bool) // context + LLM cleanup
    case pasting                               // done overlay visible, auto-dismiss
    case error(message: String)                // auto-clears to idle after 3s

    var isRecording: Bool {
        switch self {
        case .starting, .initializing, .recording: return true
        default: return false
        }
    }

    var isTranscribing: Bool {
        switch self {
        case .transcribing, .postProcessing: return true
        default: return false
        }
    }

    var statusText: String {
        switch self {
        case .idle:                    return "Ready"
        case .starting, .initializing: return "Starting..."
        case .recording:               return "Recording..."
        case .transcribing:            return "Transcribing..."
        case .postProcessing:          return "Processing..."
        case .pasting:                 return "Copied to clipboard!"
        case .error:                   return "Error"
        }
    }
}

final class AppState: ObservableObject, @unchecked Sendable {
    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let customSystemPromptStorageKey = "custom_system_prompt"
    private let customContextPromptStorageKey = "custom_context_prompt"
    private let customSystemPromptLastModifiedStorageKey = "custom_system_prompt_last_modified"
    private let customContextPromptLastModifiedStorageKey = "custom_context_prompt_last_modified"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let postProcessingEnabledStorageKey = "post_processing_enabled"
    private let minimumRecordingDurationStorageKey = "minimum_recording_duration_ms"
    private let soundEnabledStorageKey = "sound_enabled"
    private let transcribingIndicatorDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = 20

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
            contextService = AppContextService(apiKey: apiKey, baseURL: apiBaseURL, customContextPrompt: customContextPrompt)
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            persistAPIBaseURL(apiBaseURL)
            contextService = AppContextService(apiKey: apiKey, baseURL: apiBaseURL, customContextPrompt: customContextPrompt)
        }
    }

    @Published var selectedHotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedHotkey.rawValue, forKey: "hotkey_option")
            restartHotkeyMonitoring()
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptStorageKey)
        }
    }

    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: customContextPromptStorageKey)
            contextService = AppContextService(apiKey: apiKey, baseURL: apiBaseURL, customContextPrompt: customContextPrompt)
        }
    }

    @Published var customSystemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customSystemPromptLastModified, forKey: customSystemPromptLastModifiedStorageKey)
        }
    }

    @Published var customContextPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customContextPromptLastModified, forKey: customContextPromptLastModifiedStorageKey)
        }
    }

    @Published private(set) var pipelineState: SwiftPipelineState = .idle
    private var initTimerSource: DispatchSourceTimer?
    private var doneResetTask: Task<Void, Never>?
    private var doneDismissWorkItem: DispatchWorkItem?

    var isRecording: Bool { pipelineState.isRecording }
    var isTranscribing: Bool { pipelineState.isTranscribing }
    var statusText: String { pipelineState.statusText }

    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    /// Single source of truth for all permission states.
    let permissionState = PermissionStateObservable()

    /// Set when startRecording() detects missing permissions.
    /// The view layer observes this and shows a sheet. Set to nil to dismiss.
    @Published var permissionSheetKinds: [PermissionKind]? {
        didSet {
            if let kinds = permissionSheetKinds, !kinds.isEmpty {
                showPermissionWindow(kinds: kinds)
            }
        }
    }

    private var permissionWindow: NSWindow?
    private var permissionAutoCloseCancellable: AnyCancellable?

    private func showPermissionWindow(kinds: [PermissionKind]) {
        // Don't open a second one
        if let existing = permissionWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Ensure polling is running
        permissionState.startPolling()

        let view = PermissionGateView(kinds: kinds, onDismiss: { [weak self] in
                self?.permissionWindow?.close()
                self?.permissionWindow = nil
                self?.permissionSheetKinds = nil
            })
            .environmentObject(permissionState)
            .wrenflowPanel(width: 380)

        let panel = NSPanel.wrenflowPanel(content: view)
        panel.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        permissionWindow = panel

        // Auto-close when all permissions granted (with delay for success animation)
        permissionAutoCloseCancellable = permissionState.$states
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.permissionState.allRequiredSatisfied else { return }
                self.permissionAutoCloseCancellable = nil
                // Restore floating level so success animation is visible
                if let panel = self.permissionWindow as? NSPanel {
                    panel.level = .floating
                    panel.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                // Show success state briefly, then fade out
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let window = self?.permissionWindow else { return }
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.3
                        window.animator().alphaValue = 0
                    }, completionHandler: { [weak self] in
                        self?.permissionWindow?.close()
                        self?.permissionWindow = nil
                        self?.permissionSheetKinds = nil
                    })
                }
            }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.permissionWindow = nil
            self?.permissionSheetKinds = nil
            self?.permissionAutoCloseCancellable = nil
            self?.permissionState.refresh()
        }
    }

    /// Computed from permissionState for backward compat.
    var hasAccessibility: Bool {
        permissionState.get(.accessibility).isSatisfied
    }
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastPostProcessingReasoning = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    var hasScreenRecordingPermission: Bool {
        permissionState.get(.screenRecording).isSatisfied
    }
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var minimumRecordingDurationMs: Double {
        didSet {
            UserDefaults.standard.set(minimumRecordingDurationMs, forKey: minimumRecordingDurationStorageKey)
        }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
            warmUpAudioEngine()
        }
    }
    @Published var postProcessingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(postProcessingEnabled, forKey: postProcessingEnabledStorageKey)
        }
    }
    @Published var postProcessingModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingModel, forKey: postProcessingModelStorageKey)
        }
    }
    @Published var soundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: soundEnabledStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    let localTranscriptionService = LocalTranscriptionService()
    private var localTranscriptionCancellable: AnyCancellable?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var transcribingIndicatorTask: Task<Void, Never>?
    private var contextService: AppContextService
    private var contextCaptureTask: Task<AppContext?, Never>?
    private var capturedContext: AppContext?
    private var hasShownScreenshotPermissionAlert = false
    private var audioDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private let pipelineHistoryStore = PipelineHistoryStore()

    init() {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let apiBaseURL = Self.loadStoredAPIBaseURL(account: "api_base_url")
        let selectedHotkey = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? "fn") ?? .fnKey
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptStorageKey) ?? ""
        let customContextPrompt = UserDefaults.standard.string(forKey: customContextPromptStorageKey) ?? ""
        let customSystemPromptLastModified = UserDefaults.standard.string(forKey: customSystemPromptLastModifiedStorageKey) ?? ""
        let customContextPromptLastModified = UserDefaults.standard.string(forKey: customContextPromptLastModifiedStorageKey) ?? ""
        let initialAccessibility = AXIsProcessTrusted()
        let initialScreenCapturePermission = CGPreflightScreenCaptureAccess()
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.contextService = AppContextService(apiKey: apiKey, baseURL: apiBaseURL, customContextPrompt: customContextPrompt)
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.selectedHotkey = selectedHotkey
        self.customVocabulary = customVocabulary
        self.customSystemPrompt = customSystemPrompt
        self.customContextPrompt = customContextPrompt
        self.customSystemPromptLastModified = customSystemPromptLastModified
        self.customContextPromptLastModified = customContextPromptLastModified
        self.pipelineHistory = savedHistory
        // hasAccessibility and hasScreenRecordingPermission are now computed from permissionState
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        let storedMinDuration = UserDefaults.standard.double(forKey: minimumRecordingDurationStorageKey)
        self.minimumRecordingDurationMs = storedMinDuration > 0 ? storedMinDuration : 200
        self.postProcessingEnabled = UserDefaults.standard.bool(forKey: postProcessingEnabledStorageKey)
        self.postProcessingModel = UserDefaults.standard.string(forKey: postProcessingModelStorageKey) ?? "meta-llama/llama-4-scout-17b-16e-instruct"
        // Default to true if key not set (object(forKey:) returns nil for unset keys)
        self.soundEnabled = UserDefaults.standard.object(forKey: soundEnabledStorageKey) as? Bool ?? true

        refreshAvailableMicrophones()
        installAudioDeviceListener()

        // Forward localTranscriptionService changes to trigger SwiftUI updates
        localTranscriptionCancellable = localTranscriptionService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // Initialize local transcription if setup is complete; otherwise deferred to setup wizard
        if hasCompletedSetup {
            localTranscriptionService.initialize()
        }

        // Pre-warm audio engine only if setup is complete AND mic is already authorized.
        // Accessing AVAudioEngine.inputNode triggers the system mic dialog if undetermined.
        if hasCompletedSetup && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            warmUpAudioEngine()
        }

        // Initialize Rust pipeline bridge
        #if canImport(wrenflow_ffiFFI)
        self.rustPipelineBridge = RustPipelineBridge(appState: self, overlayManager: overlayManager)
        #endif
    }

    func warmUpAfterSetup() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        warmUpAudioEngine()
    }

    private func warmUpAudioEngine() {
        let deviceUID = selectedMicrophoneID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.audioRecorder.warmUp(deviceUID: deviceUID)
        }
    }

    deinit {
        removeAudioDeviceListener()
    }

    // MARK: - Pipeline State Machine

    func transition(to newState: SwiftPipelineState) {
        let oldState = pipelineState

        // Exit actions
        switch oldState {
        case .starting, .initializing:
            initTimerSource?.cancel()
            initTimerSource = nil
        case .recording:
            audioLevelCancellable?.cancel()
            audioLevelCancellable = nil
        case .transcribing, .postProcessing:
            transcribingIndicatorTask?.cancel()
            transcribingIndicatorTask = nil
        case .pasting:
            doneDismissWorkItem?.cancel()
            doneDismissWorkItem = nil
            doneResetTask?.cancel()
            doneResetTask = nil
        case .error:
            doneResetTask?.cancel()
            doneResetTask = nil
            errorMessage = nil
        case .idle:
            break
        }

        pipelineState = newState
        os_log(.info, log: recordingLog, "pipeline: %{public}@ → %{public}@",
               String(describing: oldState), String(describing: newState))

        // Enter actions
        switch newState {
        case .idle:
            audioLevelCancellable?.cancel()
            audioLevelCancellable = nil
            if oldState != .idle {
                overlayManager.dismiss()
            }

        case .starting:
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.5)
            timer.setEventHandler { [weak self] in
                guard let self, self.pipelineState == .starting else { return }
                self.transition(to: .initializing)
            }
            timer.resume()
            initTimerSource = timer

        case .initializing:
            overlayManager.showInitializing()

        case .recording:
            if case .initializing = oldState {
                overlayManager.transitionToRecording()
            } else {
                overlayManager.showRecording()
            }
            if soundEnabled { NSSound(named: "Tink")?.play() }

        case .transcribing(let showingIndicator):
            if !showingIndicator {
                overlayManager.slideUpToNotch { }
                if soundEnabled { NSSound(named: "Pop")?.play() }
                let delay = transcribingIndicatorDelay
                transcribingIndicatorTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        await MainActor.run { [weak self] in
                            guard let self, self.pipelineState.isTranscribing else { return }
                            self.transition(to: .transcribing(showingIndicator: true))
                        }
                    } catch {}
                }
            } else {
                overlayManager.showTranscribing()
            }

        case .postProcessing(let showingIndicator):
            if !showingIndicator {
                let delay = transcribingIndicatorDelay
                transcribingIndicatorTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        await MainActor.run { [weak self] in
                            guard let self, case .postProcessing = self.pipelineState else { return }
                            self.transition(to: .postProcessing(showingIndicator: true))
                        }
                    } catch {}
                }
            } else {
                overlayManager.showTranscribing()
            }

        case .pasting:
            overlayManager.showDone()
            let workItem = DispatchWorkItem { [weak self] in
                self?.overlayManager.dismiss()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
            doneDismissWorkItem = workItem
            doneResetTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run { [weak self] in
                        guard let self, case .pasting = self.pipelineState else { return }
                        self.transition(to: .idle)
                    }
                } catch {}
            }

        case .error(let message):
            overlayManager.dismiss()
            errorMessage = message
            doneResetTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run { [weak self] in
                        guard let self, case .error = self.pipelineState else { return }
                        self.transition(to: .idle)
                    }
                } catch {}
            }
        }
    }

    private func removeAudioDeviceListener() {
        guard let block = audioDeviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        audioDeviceListenerBlock = nil
    }

    private static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    private static let defaultAPIBaseURL = "https://api.groq.com/openai/v1"

    private static func loadStoredAPIBaseURL(account: String) -> String {
        if let stored = AppSettingsStorage.load(account: account), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return defaultAPIBaseURL
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
            AppSettingsStorage.delete(account: apiBaseURLStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiBaseURLStorageKey)
        }
    }

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Wrenflow"
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    static func saveAudioFile(from tempURL: URL) -> String? {
        let fileName = UUID().uuidString + "." + tempURL.pathExtension
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return fileName
        } catch {
            return nil
        }
    }

    private static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    /// Start permission polling. Delegates to the single PermissionStateObservable.
    func startAccessibilityPolling() {
        permissionState.startPolling()
    }

    func stopAccessibilityPolling() {
        permissionState.stopPolling()
    }

    func openAccessibilitySettings() {
        permissionState.request(.accessibility)
    }

    func hasScreenCapturePermission() -> Bool {
        permissionState.get(.screenRecording).isSatisfied
    }

    func requestScreenCapturePermission() {
        // ScreenCaptureKit triggers the "Screen & System Audio Recording"
        // permission dialog on macOS Sequoia+, correctly identifying the
        // running app (unlike the legacy CGWindowListCreateImage path).
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.permissionState.refresh()
            }
        }
    }

    func openScreenCaptureSettings() {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure without re-triggering didSet
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    func refreshAvailableMicrophones() {
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func installAudioDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAvailableMicrophones()
            }
        }
        audioDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    func startHotkeyMonitoring() {
        hotkeyManager.onKeyDown = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyUp()
            }
        }
        hotkeyManager.start(option: selectedHotkey)
    }

    private func restartHotkeyMonitoring() {
        hotkeyManager.start(option: selectedHotkey)
    }

    private var canStartRecording: Bool {
        switch pipelineState {
        case .idle, .pasting, .error: return true
        default: return false
        }
    }

    private func handleHotkeyDown() {
        os_log(.info, log: recordingLog, "handleHotkeyDown() fired, pipelineState=%{public}@", String(describing: pipelineState))

        #if canImport(wrenflow_ffiFFI)
        if let bridge = rustPipelineBridge {
            // Check permissions first
            permissionState.refresh()
            let missing = permissionState.missingRequired
            if !missing.isEmpty {
                permissionSheetKinds = missing
                return
            }
            // Delegate to Rust FSM
            if bridge.handleHotkeyDown() {
                // Rust accepted → start audio recording
                beginRecordingForRust()
            }
            return
        }
        #endif

        // Fallback: Swift FSM
        guard canStartRecording else { return }
        if pipelineState != .idle { transition(to: .idle) }
        startRecording()
    }

    private func handleHotkeyUp() {
        #if canImport(wrenflow_ffiFFI)
        if let bridge = rustPipelineBridge {
            guard pipelineState.isRecording else { return }
            let result = audioRecorder.stopRecording()
            let durationMs = result?.durationMs ?? 0
            if bridge.handleHotkeyUp(recordingDurationMs: durationMs) {
                // Rust accepted → run transcription
                if let fileURL = result?.fileURL {
                    runTranscriptionForRust(fileURL: fileURL, bridge: bridge)
                }
            }
            return
        }
        #endif

        // Fallback: Swift FSM
        guard pipelineState.isRecording else { return }
        stopAndTranscribe()
    }

    func startRecordingFromCLI() {
        guard canStartRecording else { return }
        if pipelineState != .idle {
            transition(to: .idle)
        }
        startRecording()
    }

    func stopRecordingFromCLI() {
        guard pipelineState.isRecording else { return }
        stopAndTranscribe()
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, pipelineState=%{public}@", String(describing: pipelineState))
        if pipelineState.isRecording {
            stopAndTranscribe()
        } else if canStartRecording {
            if pipelineState != .idle {
                transition(to: .idle)
            }
            startRecording()
        }
    }

    private func startRecording() {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")

        // Check all required permissions via single source of truth
        permissionState.refresh()
        let missing = permissionState.missingRequired
        if !missing.isEmpty {
            os_log(.info, log: recordingLog, "missing permissions: %{public}@", missing.map(\.label).joined(separator: ", "))
            // Set the published property — the view layer reacts and shows a sheet
            permissionSheetKinds = missing
            return
        }

        os_log(.info, log: recordingLog, "all permissions OK: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        beginRecording()
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    private func beginRecording() {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        errorMessage = nil
        hasShownScreenshotPermissionAlert = false
        transition(to: .starting)

        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pipelineState == .starting || self.pipelineState == .initializing else { return }
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.transition(to: .recording)
            }
        }

        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async {
                    if self.postProcessingEnabled {
                        self.startContextCapture()
                    }
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    self.transition(to: .error(message: self.formattedRecordingStartError(error)))
                }
            }
        }
    }

    // MARK: - Rust bridge recording helpers

    #if canImport(wrenflow_ffiFFI)
    /// Start audio recording for the Rust pipeline (no Swift FSM transition).
    private func beginRecordingForRust() {
        errorMessage = nil
        hasShownScreenshotPermissionAlert = false
        let deviceUID = selectedMicrophoneID

        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                self?.rustPipelineBridge?.onFirstAudio()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                DispatchQueue.main.async {
                    if self.postProcessingEnabled { self.startContextCapture() }
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in self?.overlayManager.updateAudioLevel(level) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.rustPipelineBridge?.onPipelineError(message: self.formattedRecordingStartError(error))
                }
            }
        }
    }

    /// Run transcription and report result back to Rust engine.
    private func runTranscriptionForRust(fileURL: URL, bridge: RustPipelineBridge) {
        Task {
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let transcript = try await localTranscriptionService.transcribe(fileURL: fileURL)
                let durationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                await MainActor.run {
                    bridge.onTranscriptionComplete(
                        rawTranscript: transcript,
                        durationMs: durationMs,
                        provider: "local"
                    )
                    // If Rust says post-processing needed, run it
                    if self.postProcessingEnabled && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.runPostProcessingForRust(rawTranscript: transcript, bridge: bridge)
                    }
                }
            } catch {
                await MainActor.run {
                    bridge.onPipelineError(message: "Transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Run post-processing and report result back to Rust.
    private func runPostProcessingForRust(rawTranscript: String, bridge: RustPipelineBridge) {
        let service = PostProcessingService(apiKey: apiKey, baseURL: apiBaseURL, model: postProcessingModel)
        let contextSummary = capturedContext?.contextSummary ?? ""
        let vocab = customVocabulary
        let customPrompt = customSystemPrompt

        Task {
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let context = AppContext(
                    appName: capturedContext?.appName ?? "",
                    bundleIdentifier: capturedContext?.bundleIdentifier ?? "",
                    windowTitle: capturedContext?.windowTitle ?? "",
                    selectedText: nil, currentActivity: contextSummary,
                    contextPrompt: nil, screenshotDataURL: capturedContext?.screenshotDataURL,
                    screenshotMimeType: nil, screenshotError: nil, screenshotDurationMs: nil,
                    llmInferenceDurationMs: nil, totalCaptureDurationMs: nil,
                    screenshotWindowListMs: nil, screenshotWindowSearchMs: nil,
                    screenshotCaptureMs: nil, screenshotScContentMs: nil, screenshotEncodeMs: nil,
                    screenshotMethod: nil, screenshotImageWidth: nil, screenshotImageHeight: nil
                )
                let result = try await service.postProcess(
                    transcript: rawTranscript, context: context,
                    customVocabulary: vocab, customSystemPrompt: customPrompt
                )
                let durationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                await MainActor.run {
                    bridge.onPostProcessingComplete(
                        rawTranscript: rawTranscript,
                        transcript: result.transcript,
                        prompt: result.prompt,
                        reasoning: result.reasoning,
                        durationMs: durationMs,
                        status: "done"
                    )
                }
            } catch {
                await MainActor.run {
                    bridge.onPostProcessingComplete(
                        rawTranscript: rawTranscript,
                        transcript: rawTranscript,
                        prompt: "", reasoning: "",
                        durationMs: 0,
                        status: "Error: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
    #endif

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    private func stopAndTranscribe() {
        debugStatusMessage = "Preparing audio"
        let sessionContext = capturedContext
        let inFlightContextTask = contextCaptureTask
        capturedContext = nil
        contextCaptureTask = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastPostProcessingReasoning = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"

        guard let recordingResult = audioRecorder.stopRecording() else {
            os_log(.info, log: recordingLog, "stopRecording() returned nil — treating as accidental tap")
            audioRecorder.cleanup()
            inFlightContextTask?.cancel()
            transition(to: .idle)
            return
        }
        let fileURL = recordingResult.fileURL
        let recordingDurationMs = recordingResult.durationMs
        let audioFileSizeBytes = recordingResult.fileSizeBytes
        os_log(.info, log: recordingLog, "stopRecording() returned file: %{public}@, duration=%.1fms, size=%lld bytes", fileURL.path, recordingDurationMs, audioFileSizeBytes)

        if recordingDurationMs < minimumRecordingDurationMs {
            os_log(.info, log: recordingLog, "recording too short (%.0fms < %.0fms) — dismissing",
                   recordingDurationMs, minimumRecordingDurationMs)
            audioRecorder.cleanup()
            inFlightContextTask?.cancel()
            transition(to: .idle)
            return
        }

        if audioFileSizeBytes < 1000 {
            os_log(.error, log: recordingLog, "WARNING: audio file suspiciously small (%lld bytes), transcription may fail", audioFileSizeBytes)
        }
        let savedAudioFileName = Self.saveAudioFile(from: fileURL)
        debugStatusMessage = "Transcribing audio"
        errorMessage = nil
        transition(to: .transcribing(showingIndicator: false))

        os_log(.info, log: recordingLog, "creating post-processing service, apiBaseURL=%{public}@, model=%{public}@, enabled=%{public}@", apiBaseURL, postProcessingModel, postProcessingEnabled ? "true" : "false")
        let capturedPostProcessingModel = postProcessingModel
        let capturedPostProcessingEnabled = postProcessingEnabled
        let postProcessingService = (!capturedPostProcessingEnabled || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? nil
            : PostProcessingService(apiKey: apiKey, baseURL: apiBaseURL, model: postProcessingModel)

        Task {
            do {
                let pipelineStart = CFAbsoluteTimeGetCurrent()

                // Stage 1: Transcription (always local)
                let transcriptionStart = CFAbsoluteTimeGetCurrent()
                let rawTranscript = try await self.localTranscriptionService.transcribe(fileURL: fileURL)
                let transcriptionDurationMs = (CFAbsoluteTimeGetCurrent() - transcriptionStart) * 1000
                os_log(.info, log: recordingLog, "transcription took %.1fms", transcriptionDurationMs)

                os_log(.info, log: recordingLog, "rawTranscript: '%{public}@'", rawTranscript)

                // Stage 2: Context resolution + Post-processing (only if enabled)
                let contextDurationMs: Double
                let postProcessingDurationMs: Double
                let appContext: AppContext
                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String
                let postProcessingReasoning: String

                if let postProcessingService {
                    // Transition to postProcessing state, carrying over indicator visibility
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if case .transcribing(let indicatorShowing) = self.pipelineState {
                            self.transition(to: .postProcessing(showingIndicator: indicatorShowing))
                        }
                        self.debugStatusMessage = "Resolving context"
                    }

                    // Context resolution
                    let contextStart = CFAbsoluteTimeGetCurrent()
                    if let sessionContext {
                        os_log(.info, log: recordingLog, "using sessionContext for post-processing")
                        appContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        os_log(.info, log: recordingLog, "using inFlightContext for post-processing")
                        appContext = inFlightContext
                    } else {
                        os_log(.info, log: recordingLog, "using fallbackContext for post-processing")
                        appContext = fallbackContextAtStop()
                    }
                    contextDurationMs = (CFAbsoluteTimeGetCurrent() - contextStart) * 1000
                    os_log(.info, log: recordingLog, "context resolution took %.1fms", contextDurationMs)
                    os_log(.info, log: recordingLog, "appContext: app=%{public}@, window=%{public}@, activity=%{public}@", appContext.appName ?? "nil", appContext.windowTitle ?? "nil", appContext.currentActivity)

                    await MainActor.run { [weak self] in
                        self?.debugStatusMessage = "Running post-processing"
                    }

                    // LLM post-processing
                    let postProcessingStart = CFAbsoluteTimeGetCurrent()
                    do {
                        let postProcessingResult = try await postProcessingService.postProcess(
                            transcript: rawTranscript,
                            context: appContext,
                            customVocabulary: customVocabulary,
                            customSystemPrompt: customSystemPrompt
                        )
                        finalTranscript = postProcessingResult.transcript
                        processingStatus = "Post-processing succeeded"
                        postProcessingPrompt = postProcessingResult.prompt
                        postProcessingReasoning = postProcessingResult.reasoning
                        os_log(.info, log: recordingLog, "post-processing reasoning: %{public}@", postProcessingReasoning)
                    } catch {
                        os_log(.error, log: recordingLog, "post-processing FAILED: %{public}@", error.localizedDescription)
                        finalTranscript = rawTranscript
                        processingStatus = "Post-processing failed, using raw transcript"
                        postProcessingPrompt = ""
                        postProcessingReasoning = "Error: \(error.localizedDescription)"
                    }
                    postProcessingDurationMs = (CFAbsoluteTimeGetCurrent() - postProcessingStart) * 1000
                } else {
                    // Post-processing disabled or no API key — use raw transcript directly
                    inFlightContextTask?.cancel()
                    appContext = fallbackContextAtStop()
                    contextDurationMs = 0
                    postProcessingDurationMs = 0
                    finalTranscript = rawTranscript
                    postProcessingPrompt = ""
                    if !capturedPostProcessingEnabled {
                        os_log(.info, log: recordingLog, "post-processing disabled — using raw transcript")
                        processingStatus = "Post-processing disabled"
                        postProcessingReasoning = "Post-processing disabled by user"
                    } else {
                        os_log(.info, log: recordingLog, "no API key — skipping post-processing, using raw transcript")
                        processingStatus = "Post-processing skipped (no API key)"
                        postProcessingReasoning = "No API key configured"
                    }
                }

                let totalDurationMs = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000
                os_log(.info, log: recordingLog, "post-processing took %.1fms, total pipeline %.1fms", postProcessingDurationMs, totalDurationMs)

                await MainActor.run {
                    self.lastContextSummary = appContext.contextSummary
                    self.lastContextScreenshotDataURL = appContext.screenshotDataURL
                    self.lastContextScreenshotStatus = appContext.screenshotError
                        ?? "available (\(appContext.screenshotMimeType ?? "image"))"
                    let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedFinalTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastPostProcessingPrompt = postProcessingPrompt
                    self.lastPostProcessingReasoning = postProcessingReasoning
                    self.lastRawTranscript = trimmedRawTranscript
                    self.lastPostProcessedTranscript = trimmedFinalTranscript
                    self.lastPostProcessingStatus = processingStatus
                    self.lastTranscript = trimmedFinalTranscript
                    self.debugStatusMessage = "Done"

                    os_log(.info, log: recordingLog, "finalTranscript: '%{public}@'", trimmedFinalTranscript)
                    var pasteDurationMs: Double? = nil
                    if trimmedFinalTranscript.isEmpty {
                        os_log(.info, log: recordingLog, "transcript empty — dismissing")
                        self.transition(to: .idle)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(trimmedFinalTranscript, forType: .string)
                        os_log(.info, log: recordingLog, "clipboard set, pasting")

                        let pasteStart = CFAbsoluteTimeGetCurrent()
                        self.pasteAtCursor()
                        pasteDurationMs = (CFAbsoluteTimeGetCurrent() - pasteStart) * 1000
                        os_log(.info, log: recordingLog, "pasteAtCursor() took %.1fms", pasteDurationMs ?? 0)

                        self.transition(to: .pasting)
                    }

                    let processingDurationMs = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000
                    let finalTotalDurationMs = recordingDurationMs + processingDurationMs

                    var metrics = PipelineMetrics()
                    metrics.set("recording.durationMs", recordingDurationMs)
                    metrics.set("recording.fileSizeBytes", Int(audioFileSizeBytes))
                    metrics.set("transcription.durationMs", transcriptionDurationMs)
                    metrics.set("transcription.provider", "local" as String)
                    metrics.set("context.totalMs", appContext.totalCaptureDurationMs)
                    metrics.set("context.resolutionMs", contextDurationMs)
                    metrics.set("context.screenshotMs", appContext.screenshotDurationMs)
                    metrics.set("context.llmMs", appContext.llmInferenceDurationMs)
                    metrics.set("postProcessing.durationMs", postProcessingDurationMs)
                    metrics.set("postProcessing.model", capturedPostProcessingModel)
                    metrics.set("postProcessing.enabled", capturedPostProcessingEnabled)
                    metrics.set("postProcessing.skipped", postProcessingService == nil)
                    metrics.set("paste.durationMs", pasteDurationMs)
                    metrics.set("pipeline.totalMs", finalTotalDurationMs)
                    metrics.set("pipeline.processingMs", processingDurationMs)
                    metrics.set("pipeline.outcome", trimmedFinalTranscript.isEmpty ? "empty" : "pasted" as String)
                    metrics.set("screenshot.windowListMs", appContext.screenshotWindowListMs)
                    metrics.set("screenshot.windowSearchMs", appContext.screenshotWindowSearchMs)
                    metrics.set("screenshot.captureMs", appContext.screenshotCaptureMs)
                    metrics.set("screenshot.scContentMs", appContext.screenshotScContentMs)
                    metrics.set("screenshot.encodeMs", appContext.screenshotEncodeMs)
                    metrics.set("screenshot.method", appContext.screenshotMethod)
                    metrics.set("screenshot.width", appContext.screenshotImageWidth)
                    metrics.set("screenshot.height", appContext.screenshotImageHeight)
                    // Engine metrics from recording result
                    metrics.set("engine.initMs", recordingResult.engineInitMs)
                    metrics.set("engine.reused", recordingResult.engineReused)
                    metrics.set("engine.warmedUp", recordingResult.engineWarmedUp)
                    metrics.set("engine.startMs", recordingResult.engineStartMs)
                    metrics.set("engine.inputSampleRate", recordingResult.inputSampleRate)
                    metrics.set("engine.backend", recordingResult.engineBackend)
                    metrics.set("engine.bufferCount", recordingResult.bufferCount)
                    metrics.set("engine.firstTapCallbackMs", recordingResult.firstTapCallbackMs)
                    metrics.set("engine.firstNonSilentBufferMs", recordingResult.firstNonSilentBufferMs)
                    metrics.set("engine.firstBufferFrames", recordingResult.firstBufferFrames)
                    metrics.set("engine.armedMs", recordingResult.armedMs)
                    metrics.set("engine.fileReadyMs", recordingResult.fileReadyMs)
                    // HAL metrics
                    metrics.set("hal.bufferFrames", recordingResult.halBufferFrames)
                    metrics.set("hal.bufferDurationMs", recordingResult.halBufferDurationMs)
                    metrics.set("hal.minFrames", recordingResult.halMinFrames)
                    metrics.set("hal.maxFrames", recordingResult.halMaxFrames)
                    metrics.set("hal.bufferSetTo", recordingResult.halBufferSetTo)
                    metrics.set("hal.bufferActual", recordingResult.halBufferActual)

                    self.recordPipelineHistoryEntry(
                        rawTranscript: trimmedRawTranscript,
                        postProcessedTranscript: trimmedFinalTranscript,
                        postProcessingPrompt: postProcessingPrompt,
                        postProcessingReasoning: postProcessingReasoning,
                        context: appContext,
                        processingStatus: processingStatus,
                        audioFileName: savedAudioFileName,
                        metrics: metrics
                    )

                    self.audioRecorder.cleanup()
                }
            } catch {
                os_log(.error, log: recordingLog, "PIPELINE ERROR: %{public}@", error.localizedDescription)
                let resolvedContext: AppContext
                if let sessionContext {
                    resolvedContext = sessionContext
                } else if let inFlightContext = await inFlightContextTask?.value {
                    resolvedContext = inFlightContext
                } else {
                    resolvedContext = fallbackContextAtStop()
                }
                await MainActor.run {
                    self.audioRecorder.cleanup()
                    self.lastPostProcessedTranscript = ""
                    self.lastRawTranscript = ""
                    self.lastContextSummary = ""
                    self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                    self.lastPostProcessingPrompt = ""
                    self.lastPostProcessingReasoning = ""
                    self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                    self.lastContextScreenshotStatus = resolvedContext.screenshotError
                        ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                    var errorMetrics = PipelineMetrics()
                    errorMetrics.set("recording.durationMs", recordingDurationMs)
                    errorMetrics.set("recording.fileSizeBytes", Int(audioFileSizeBytes))
                    errorMetrics.set("transcription.provider", "local" as String)
                    errorMetrics.set("postProcessing.model", capturedPostProcessingModel)
                    errorMetrics.set("pipeline.outcome", "error" as String)
                    errorMetrics.set("screenshot.windowListMs", resolvedContext.screenshotWindowListMs)
                    errorMetrics.set("screenshot.windowSearchMs", resolvedContext.screenshotWindowSearchMs)
                    errorMetrics.set("screenshot.captureMs", resolvedContext.screenshotCaptureMs)
                    errorMetrics.set("screenshot.scContentMs", resolvedContext.screenshotScContentMs)
                    errorMetrics.set("screenshot.encodeMs", resolvedContext.screenshotEncodeMs)
                    errorMetrics.set("screenshot.method", resolvedContext.screenshotMethod)
                    errorMetrics.set("screenshot.width", resolvedContext.screenshotImageWidth)
                    errorMetrics.set("screenshot.height", resolvedContext.screenshotImageHeight)
                    errorMetrics.set("engine.initMs", recordingResult.engineInitMs)
                    errorMetrics.set("engine.reused", recordingResult.engineReused)
                    errorMetrics.set("engine.warmedUp", recordingResult.engineWarmedUp)
                    errorMetrics.set("engine.startMs", recordingResult.engineStartMs)
                    errorMetrics.set("engine.inputSampleRate", recordingResult.inputSampleRate)
                    errorMetrics.set("engine.backend", recordingResult.engineBackend)
                    errorMetrics.set("engine.bufferCount", recordingResult.bufferCount)
                    errorMetrics.set("engine.firstTapCallbackMs", recordingResult.firstTapCallbackMs)
                    errorMetrics.set("engine.firstNonSilentBufferMs", recordingResult.firstNonSilentBufferMs)
                    errorMetrics.set("engine.firstBufferFrames", recordingResult.firstBufferFrames)
                    errorMetrics.set("engine.armedMs", recordingResult.armedMs)
                    errorMetrics.set("engine.fileReadyMs", recordingResult.fileReadyMs)
                    errorMetrics.set("hal.bufferFrames", recordingResult.halBufferFrames)
                    errorMetrics.set("hal.bufferDurationMs", recordingResult.halBufferDurationMs)
                    errorMetrics.set("hal.minFrames", recordingResult.halMinFrames)
                    errorMetrics.set("hal.maxFrames", recordingResult.halMaxFrames)
                    errorMetrics.set("hal.bufferSetTo", recordingResult.halBufferSetTo)
                    errorMetrics.set("hal.bufferActual", recordingResult.halBufferActual)
                    self.recordPipelineHistoryEntry(
                        rawTranscript: "",
                        postProcessedTranscript: "",
                        postProcessingPrompt: "",
                        context: resolvedContext,
                        processingStatus: "Error: \(error.localizedDescription)",
                        audioFileName: savedAudioFileName,
                        metrics: errorMetrics
                    )
                    self.transition(to: .error(message: error.localizedDescription))
                }
            }
        }
    }

    private func recordPipelineHistoryEntry(
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        postProcessingReasoning: String = "",
        context: AppContext,
        processingStatus: String,
        audioFileName: String? = nil,
        metrics: PipelineMetrics
    ) {
        let newEntry = PipelineHistoryItem(
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            postProcessingReasoning: postProcessingReasoning,
            contextSummary: context.contextSummary,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: context.screenshotError
                ?? "available (\(context.screenshotMimeType ?? "image"))",
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName,
            metrics: metrics
        )
        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
    }

    private func startContextCapture() {
        contextCaptureTask?.cancel()
        capturedContext = nil
        lastContextSummary = "Collecting app context..."
        lastPostProcessingStatus = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "Collecting screenshot..."

        contextCaptureTask = Task { [weak self] in
            guard let self else { return nil }
            let context = await self.contextService.collectContext()
            await MainActor.run {
                self.capturedContext = context
                self.lastContextSummary = context.contextSummary
                self.lastContextScreenshotDataURL = context.screenshotDataURL
                self.lastContextScreenshotStatus = context.screenshotError
                    ?? "available (\(context.screenshotMimeType ?? "image"))"
                self.lastPostProcessingStatus = "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
            }
            return context
        }
    }

    private func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: "Could not refresh app context at stop time; using text-only post-processing.",
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "No app context captured before stop",
            screenshotDurationMs: nil,
            llmInferenceDurationMs: nil,
            totalCaptureDurationMs: nil,
            screenshotWindowListMs: nil,
            screenshotWindowSearchMs: nil,
            screenshotCaptureMs: nil,
            screenshotScContentMs: nil,
            screenshotEncodeMs: nil,
            screenshotMethod: nil,
            screenshotImageWidth: nil,
            screenshotImageHeight: nil
        )
    }

    private func focusedWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindowTitle(from: appElement)
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        guard let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }

        return trimmedText(windowTitle)
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleScreenshotCaptureIssue(_ message: String?) {
        guard let message, !message.isEmpty else {
            hasShownScreenshotPermissionAlert = false
            return
        }

        os_log(.error, "Screenshot capture issue: %{public}@", message)

        if isScreenCapturePermissionError(message) && !hasShownScreenshotPermissionAlert {
            hasShownScreenshotPermissionAlert = true

            // Permission errors are fatal — stop recording
            _ = audioRecorder.stopRecording()
            audioRecorder.cleanup()
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            capturedContext = nil
            transition(to: .idle)

            NSSound(named: "Basso")?.play()
            showScreenshotPermissionAlert(message: message)
        }
        // Non-permission errors (transient failures) — continue recording without context
    }

    private func isScreenCapturePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("permission") || lowered.contains("screen recording")
    }

    private func showScreenshotPermissionAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "\(message)\n\nWrenflow requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable Wrenflow."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func showScreenshotCaptureErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screenshot Capture Failed"
        alert.informativeText = "\(message)\n\nA screenshot is required for context-aware transcription. Recording has been stopped."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        _ = alert.runModal()
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        overlayManager.dismiss()
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
