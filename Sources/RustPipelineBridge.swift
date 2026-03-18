// RustPipelineBridge.swift
// Bridges the Rust FfiPipelineEngine (via UniFFI) into the Swift AppState world.

import Foundation
import AppKit
import os.log

private let bridgeLog = OSLog(subsystem: "me.gulya.wrenflow", category: "RustBridge")

// MARK: - SwiftPipelineListener

/// Conforms to the UniFFI-generated FfiPipelineListener protocol.
/// Receives callbacks from the Rust PipelineEngine and translates them
/// into Swift-side effects (UI updates, sounds, paste, history).
///
/// All callbacks arrive on an arbitrary Rust thread. Each method dispatches
/// to MainActor for any UI or AppState mutation.
final class SwiftPipelineListener: FfiPipelineListener {

    /// Weak back-reference to AppState for side effects.
    /// Using `unowned` would be unsafe since callbacks can fire after AppState deinit.
    private weak var appState: AppState?

    /// The overlay manager to drive recording/transcribing/done overlays.
    private weak var overlayManager: RecordingOverlayManager?

    init(appState: AppState, overlayManager: RecordingOverlayManager) {
        self.appState = appState
        self.overlayManager = overlayManager
    }

    // MARK: FfiPipelineListener

    func onStateChanged(old: PipelineState, new: PipelineState) {
        os_log(.info, log: bridgeLog, "Rust state: %{public}@ -> %{public}@",
               String(describing: old), String(describing: new))

        DispatchQueue.main.async { [weak self] in
            guard let self, let appState = self.appState else { return }
            appState.handleRustStateChange(old: old, new: new)
        }
    }

    func onPasteText(text: String) {
        os_log(.info, log: bridgeLog, "Rust: paste text (%d chars)", text.count)

        DispatchQueue.main.async { [weak self] in
            guard let self, let appState = self.appState else { return }
            appState.handleRustPasteText(text)
        }
    }

    func onPlaySound(sound: PipelineSound) {
        os_log(.info, log: bridgeLog, "Rust: play sound %{public}@", String(describing: sound))

        DispatchQueue.main.async {
            switch sound {
            case .recordingStarted:
                NSSound(named: "Tink")?.play()
            case .recordingStopped:
                NSSound(named: "Pop")?.play()
            }
        }
    }

    func onError(message: String) {
        os_log(.error, log: bridgeLog, "Rust pipeline error: %{public}@", message)

        DispatchQueue.main.async { [weak self] in
            guard let self, let appState = self.appState else { return }
            appState.handleRustError(message)
        }
    }

    func onHistoryEntryAdded(entry: HistoryEntry) {
        os_log(.info, log: bridgeLog, "Rust: history entry added id=%{public}@", entry.id)

        DispatchQueue.main.async { [weak self] in
            guard let self, let appState = self.appState else { return }
            appState.handleRustHistoryEntry(entry)
        }
    }
}

// MARK: - RustPipelineBridge

/// Wraps FfiPipelineEngine and provides the same interface that AppState
/// currently uses for pipeline control: handleHotkeyDown/Up, state queries, etc.
///
/// AppState creates one RustPipelineBridge and delegates pipeline control to it.
/// The bridge owns the FfiPipelineEngine and the SwiftPipelineListener.
final class RustPipelineBridge {

    private let engine: FfiPipelineEngine
    private let listener: SwiftPipelineListener

    // Timer sources for callbacks that Rust expects Swift to schedule.
    // Rust tells us the state; Swift schedules the OS timer and calls back.
    private var initTimeoutTimer: DispatchSourceTimer?
    private var indicatorTimeoutTimer: DispatchSourceTimer?
    private var dismissTimeoutTimer: DispatchSourceTimer?

    /// Durations matching the current Swift FSM behavior.
    private let initTimeoutDelay: TimeInterval = 0.5
    private let indicatorTimeoutDelay: TimeInterval = 1.0
    private let dismissOverlayDelay: TimeInterval = 0.7
    private let dismissResetDelay: TimeInterval = 3.0

    init(appState: AppState, overlayManager: RecordingOverlayManager) {
        let listener = SwiftPipelineListener(appState: appState, overlayManager: overlayManager)
        self.listener = listener

        let config = RustPipelineBridge.makeConfig(from: appState)
        self.engine = FfiPipelineEngine(config: config, listener: listener)

        os_log(.info, log: bridgeLog, "RustPipelineBridge initialized")
    }

    // MARK: - Hotkey interface (called by AppState)

    /// Returns true if the engine accepted the key-down event.
    @discardableResult
    func handleHotkeyDown() -> Bool {
        let accepted = engine.handleHotkeyDown()
        os_log(.info, log: bridgeLog, "handleHotkeyDown -> accepted=%{public}@",
               accepted ? "true" : "false")
        return accepted
    }

    /// Returns true if the engine accepted the key-up event.
    @discardableResult
    func handleHotkeyUp(recordingDurationMs: Double) -> Bool {
        let accepted = engine.handleHotkeyUp(recordingDurationMs: recordingDurationMs)
        os_log(.info, log: bridgeLog, "handleHotkeyUp(%.1fms) -> accepted=%{public}@",
               recordingDurationMs, accepted ? "true" : "false")
        return accepted
    }

    // MARK: - Callbacks from Swift async work back into Rust

    /// Called when the audio recorder reports first real audio.
    func onFirstAudio() {
        engine.onFirstAudio()
    }

    /// Called when Swift transcription completes.
    func onTranscriptionComplete(rawTranscript: String, durationMs: Double, provider: String) {
        let result = TranscriptionResult(
            rawTranscript: rawTranscript,
            durationMs: durationMs,
            provider: provider
        )
        engine.onTranscriptionComplete(result: result)
    }

    /// Called when Swift post-processing completes.
    func onPostProcessingComplete(
        rawTranscript: String,
        transcript: String,
        prompt: String,
        reasoning: String,
        durationMs: Double,
        status: String
    ) {
        // Note: The FFI PostProcessingResult is a different type from
        // Swift's PostProcessingResult in PostProcessingService.swift.
        // When both are compiled, they'll need disambiguation (e.g., module prefix).
        let result = PostProcessingResult(
            transcript: transcript,
            prompt: prompt,
            reasoning: reasoning,
            durationMs: durationMs,
            status: status
        )
        engine.onPostProcessingComplete(rawTranscript: rawTranscript, result: result)
    }

    /// Called when a pipeline error occurs on the Swift side.
    func onPipelineError(message: String) {
        engine.onPipelineError(message: message)
    }

    /// Query the current Rust pipeline state.
    func state() -> PipelineState {
        return engine.state()
    }

    /// Push updated config to Rust (e.g. when user changes settings).
    func updateConfig(from appState: AppState) {
        let config = RustPipelineBridge.makeConfig(from: appState)
        engine.updateConfig(config: config)
    }

    // MARK: - Timer management

    /// Called by AppState when Rust transitions to .starting.
    /// Schedules a timer that fires onInitTimeout after 0.5s.
    func scheduleInitTimeout() {
        cancelInitTimeout()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + initTimeoutDelay)
        timer.setEventHandler { [weak self] in
            self?.engine.onInitTimeout()
        }
        timer.resume()
        initTimeoutTimer = timer
    }

    func cancelInitTimeout() {
        initTimeoutTimer?.cancel()
        initTimeoutTimer = nil
    }

    /// Called by AppState when Rust transitions to .transcribing(showingIndicator: false)
    /// or .postProcessing(showingIndicator: false).
    /// Schedules a timer that fires onIndicatorTimeout after 1.0s.
    func scheduleIndicatorTimeout() {
        cancelIndicatorTimeout()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + indicatorTimeoutDelay)
        timer.setEventHandler { [weak self] in
            self?.engine.onIndicatorTimeout()
        }
        timer.resume()
        indicatorTimeoutTimer = timer
    }

    func cancelIndicatorTimeout() {
        indicatorTimeoutTimer?.cancel()
        indicatorTimeoutTimer = nil
    }

    /// Called by AppState when Rust transitions to .pasting.
    /// Schedules a timer that fires onDismissTimeout after 3.0s.
    func scheduleDismissTimeout() {
        cancelDismissTimeout()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + dismissResetDelay)
        timer.setEventHandler { [weak self] in
            self?.engine.onDismissTimeout()
        }
        timer.resume()
        dismissTimeoutTimer = timer
    }

    func cancelDismissTimeout() {
        dismissTimeoutTimer?.cancel()
        dismissTimeoutTimer = nil
    }

    /// Cancel all pending timers (e.g. on deinit or forced reset).
    func cancelAllTimers() {
        cancelInitTimeout()
        cancelIndicatorTimeout()
        cancelDismissTimeout()
    }

    deinit {
        cancelAllTimers()
    }

    // MARK: - Config mapping

    private static func makeConfig(from appState: AppState) -> AppConfig {
        return AppConfig(
            postProcessingEnabled: appState.postProcessingEnabled,
            postProcessingModel: appState.postProcessingModel,
            apiBaseUrl: appState.apiBaseURL,
            minimumRecordingDurationMs: appState.minimumRecordingDurationMs,
            customVocabulary: appState.customVocabulary,
            customSystemPrompt: appState.customSystemPrompt,
            customContextPrompt: appState.customContextPrompt,
            selectedHotkey: appState.selectedHotkey.rawValue,
            selectedMicrophoneId: appState.selectedMicrophoneID,
            soundEnabled: appState.soundEnabled
        )
    }
}

// MARK: - HistoryEntry -> PipelineHistoryItem conversion

extension HistoryEntry {
    /// Convert a Rust HistoryEntry into the existing Swift PipelineHistoryItem.
    func toPipelineHistoryItem() -> PipelineHistoryItem? {
        guard let uuid = UUID(uuidString: id) else {
            os_log(.error, log: bridgeLog, "Invalid UUID in HistoryEntry: %{public}@", id)
            return nil
        }

        // Decode metrics JSON back into PipelineMetrics
        let metrics: PipelineMetrics
        if let data = metricsJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PipelineMetrics.self, from: data) {
            metrics = decoded
        } else {
            metrics = PipelineMetrics()
        }

        return PipelineHistoryItem(
            id: uuid,
            timestamp: Date(timeIntervalSince1970: timestamp),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            postProcessingReasoning: postProcessingReasoning,
            contextSummary: contextSummary,
            contextPrompt: contextPrompt,
            contextScreenshotDataURL: contextScreenshotDataUrl,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: postProcessingStatus,
            debugStatus: debugStatus,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName,
            metrics: metrics
        )
    }
}

// MARK: - AppState extension for Rust bridge callbacks

/// These methods are called by SwiftPipelineListener on the main thread.
/// They translate Rust pipeline events into the same side-effects that
/// the existing Swift FSM produces.
extension AppState {

    /// Handle a Rust state transition. This drives the overlay, timers, and
    /// published pipelineState property.
    func handleRustStateChange(old: PipelineState, new: PipelineState) {
        guard let bridge = rustPipelineBridge else { return }

        // Cancel timers from old state
        switch old {
        case .starting, .initializing:
            bridge.cancelInitTimeout()
        case .transcribing, .postProcessing:
            bridge.cancelIndicatorTimeout()
        case .pasting:
            bridge.cancelDismissTimeout()
        default:
            break
        }

        // Map the Rust PipelineState to the Swift PipelineState and update UI.
        // Note: when both PipelineState enums coexist (Step 7), this mapping
        // will convert from the FFI PipelineState to the Swift PipelineState.
        // For now they have identical cases so this is a direct translation.
        switch new {
        case .idle:
            if old != .idle {
                overlayManager.dismiss()
            }
            // Update the Swift published state
            updatePipelineStateFromRust(.idle)

        case .starting:
            updatePipelineStateFromRust(.starting)
            bridge.scheduleInitTimeout()

        case .initializing:
            overlayManager.showInitializing()
            updatePipelineStateFromRust(.initializing)

        case .recording:
            switch old {
            case .initializing:
                overlayManager.transitionToRecording()
            default:
                overlayManager.showRecording()
            }
            updatePipelineStateFromRust(.recording)

        case .transcribing(let showingIndicator):
            if !showingIndicator {
                overlayManager.slideUpToNotch { }
                bridge.scheduleIndicatorTimeout()
            } else {
                overlayManager.showTranscribing()
            }
            updatePipelineStateFromRust(.transcribing(showingIndicator: showingIndicator))

        case .postProcessing(let showingIndicator):
            if !showingIndicator {
                bridge.scheduleIndicatorTimeout()
            } else {
                overlayManager.showTranscribing()
            }
            updatePipelineStateFromRust(.postProcessing(showingIndicator: showingIndicator))

        case .pasting:
            overlayManager.showDone()
            // Dismiss overlay after 0.7s, reset to idle after 3.0s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.overlayManager.dismiss()
            }
            bridge.scheduleDismissTimeout()
            updatePipelineStateFromRust(.pasting)

        case .error(let message):
            overlayManager.dismiss()
            errorMessage = message
            bridge.scheduleDismissTimeout()
            updatePipelineStateFromRust(.error(message: message))
        }
    }

    /// Called by the Rust engine when text should be pasted.
    func handleRustPasteText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastTranscript = trimmed
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        pasteAtCursorForRustBridge()
    }

    /// Called when Rust reports an error.
    func handleRustError(_ message: String) {
        errorMessage = message
    }

    /// Called when Rust adds a history entry.
    func handleRustHistoryEntry(_ entry: HistoryEntry) {
        guard let item = entry.toPipelineHistoryItem() else { return }

        lastRawTranscript = entry.rawTranscript
        lastPostProcessedTranscript = entry.postProcessedTranscript
        lastPostProcessingPrompt = entry.postProcessingPrompt ?? ""
        lastPostProcessingReasoning = entry.postProcessingReasoning ?? ""
        lastContextSummary = entry.contextSummary
        lastPostProcessingStatus = entry.postProcessingStatus
        debugStatusMessage = entry.debugStatus

        // Persist via the existing store
        // (In Step 7, this may be refactored so Rust owns persistence)
        pipelineHistory.insert(item, at: 0)
        if pipelineHistory.count > maxPipelineHistoryCount {
            pipelineHistory = Array(pipelineHistory.prefix(maxPipelineHistoryCount))
        }
    }

    // MARK: - Private helpers for Rust bridge

    /// Update the Swift @Published pipelineState from a Rust PipelineState.
    /// When both enums coexist, this converts from FFI type to Swift type.
    /// They currently have identical cases.
    func updatePipelineStateFromRust(_ ffiState: PipelineState) {
        // Convert FFI PipelineState → SwiftPipelineState
        let newState: SwiftPipelineState
        switch ffiState {
        case .idle: newState = .idle
        case .starting: newState = .starting
        case .initializing: newState = .initializing
        case .recording: newState = .recording
        case let .transcribing(showing): newState = .transcribing(showingIndicator: showing)
        case let .postProcessing(showing): newState = .postProcessing(showingIndicator: showing)
        case .pasting: newState = .pasting
        case let .error(msg): newState = .error(message: msg)
        }
        transition(to: newState)
    }

    /// Expose pasteAtCursor for the bridge. The existing pasteAtCursor() is private.
    func pasteAtCursorForRustBridge() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Stored property for AppState

extension AppState {
    private static let _rustBridgeKey = "rustPipelineBridge"

    // Store in a computed property backed by objc associated object
    // since we can't add stored properties in extensions.
    var rustPipelineBridge: RustPipelineBridge? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.rustBridge) as? RustPipelineBridge
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.rustBridge, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private enum AssociatedKeys {
    static var rustBridge = 0
}

// MARK: - SwiftAudioCaptureListener

/// Implements the Rust FfiAudioCaptureListener protocol, forwarding
/// audio-capture events to Swift closures.
final class SwiftAudioCaptureListener: FfiAudioCaptureListener, @unchecked Sendable {
    private let _onAudioLevel: (Float) -> Void
    private let _onRecordingReady: () -> Void
    private let _onError: (String) -> Void

    init(
        onRecordingReady: @escaping () -> Void,
        onAudioLevel: @escaping (Float) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self._onRecordingReady = onRecordingReady
        self._onAudioLevel = onAudioLevel
        self._onError = onError
    }

    func onAudioLevel(level: Float) {
        _onAudioLevel(level)
    }

    func onRecordingReady() {
        _onRecordingReady()
    }

    func onError(message: String) {
        _onError(message)
    }
}

// MARK: - FfiAudioDeviceInfo Identifiable conformance

extension FfiAudioDeviceInfo: Identifiable {}
