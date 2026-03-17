import SwiftUI
import AVFoundation
import Combine
import ServiceManagement

struct SetupAccordionView: View {
    var onComplete: () -> Void
    @EnvironmentObject var appState: AppState

    private enum SetupStep: Int, CaseIterable, Identifiable {
        case transcriptionProvider = 0
        case apiKey
        case micPermission
        case accessibility
        case screenRecording
        case hotkey
        case vocabulary
        case launchAtLogin
        case testTranscription

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .transcriptionProvider: return "Transcription"
            case .apiKey: return "API Key"
            case .micPermission: return "Microphone"
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .hotkey: return "Push-to-Talk Key"
            case .vocabulary: return "Custom Vocabulary"
            case .launchAtLogin: return "Launch at Login"
            case .testTranscription: return "Test"
            }
        }

        var icon: String {
            switch self {
            case .transcriptionProvider: return "waveform"
            case .apiKey: return "key.fill"
            case .micPermission: return "mic.fill"
            case .accessibility: return "hand.raised.fill"
            case .screenRecording: return "camera.viewfinder"
            case .hotkey: return "keyboard.fill"
            case .vocabulary: return "text.book.closed.fill"
            case .launchAtLogin: return "sunrise.fill"
            case .testTranscription: return "play.circle.fill"
            }
        }

        var skippable: Bool {
            switch self {
            case .apiKey, .vocabulary, .screenRecording, .testTranscription: return true
            default: return false
            }
        }
    }

    @State private var activeStep: Int = 0
    @State private var skippedSteps: Set<SetupStep> = []
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var apiKeyInput = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var customVocabularyInput = ""
    @State private var accessibilityTimer: Timer?
    @State private var screenRecordingTimer: Timer?

    private enum TestPhase: Equatable { case idle, recording, transcribing, done }
    @State private var testPhase: TestPhase = .idle
    @State private var testAudioLevel: Float = 0.0
    @State private var testTranscript = ""
    @State private var testError: String?
    @State private var testAudioLevelCancellable: AnyCancellable?

    private var steps: [SetupStep] {
        SetupStep.allCases.filter { step in
            // Only show API key step for Groq provider
            if step == .apiKey && appState.selectedTranscriptionProvider != .groq {
                return false
            }
            // Only show screen recording when an API key is available (needed for post-processing)
            if step == .screenRecording {
                let hasKey = !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !hasKey { return false }
            }
            return true
        }
    }

    private var allDone: Bool { activeStep >= steps.count }

    /// Whether the Continue button should be enabled for the current step.
    private var canContinue: Bool {
        guard !allDone else { return true }
        let step = steps[activeStep]
        switch step {
        case .micPermission:
            return micPermissionGranted
        case .accessibility:
            return accessibilityGranted
        case .apiKey:
            return !isValidatingKey
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)

                Text("Set up Wrenflow")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 20)

            // Accordion
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            let isActive = index == activeStep
                            let isDone = index < activeStep
                            let isSkipped = skippedSteps.contains(step)
                            let isLast = index == steps.count - 1

                            // Step row
                            VStack(spacing: 0) {
                                HStack(alignment: .top, spacing: 12) {
                                    // Left: connecting line with circle overlay
                                    ZStack(alignment: .top) {
                                        // Vertical line (full height)
                                        if !isLast {
                                            Rectangle()
                                                .fill(isDone ? (isSkipped ? Color.orange.opacity(0.3) : Color.green.opacity(0.3)) : Color(nsColor: .separatorColor).opacity(0.5))
                                                .frame(width: 1.5)
                                                .frame(maxHeight: .infinity)
                                        }

                                        // Circle aligned with first row
                                        stepCircle(index: index, isDone: isDone, isActive: isActive, isSkipped: isSkipped)
                                            .padding(.top, 8)
                                    }
                                    .frame(width: 24)

                                    // Right: content
                                    VStack(alignment: .leading, spacing: 0) {
                                        // Header
                                        Button {
                                            if index <= activeStep {
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                                    activeStep = index
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: step.icon)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(isDone ? Color.green : isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                                                    .frame(width: 14)

                                                Text(step.label)
                                                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                                                    .foregroundStyle(isDone ? .secondary : .primary)

                                                Spacer()

                                                if !isDone && !isActive {
                                                    // Show permission status even when collapsed
                                                    if step == .micPermission && micPermissionGranted {
                                                        Label("Granted", systemImage: "checkmark.circle.fill")
                                                            .font(.system(size: 10, weight: .medium))
                                                            .foregroundStyle(.green)
                                                    } else if step == .accessibility && accessibilityGranted {
                                                        Label("Granted", systemImage: "checkmark.circle.fill")
                                                            .font(.system(size: 10, weight: .medium))
                                                            .foregroundStyle(.green)
                                                    } else if step == .screenRecording && appState.hasScreenRecordingPermission {
                                                        Label("Granted", systemImage: "checkmark.circle.fill")
                                                            .font(.system(size: 10, weight: .medium))
                                                            .foregroundStyle(.green)
                                                    }
                                                }
                                                if isDone {
                                                    if isSkipped {
                                                        Text("Skipped")
                                                            .font(.system(size: 10, weight: .medium))
                                                            .foregroundStyle(.orange)
                                                    } else {
                                                        Text("Done")
                                                            .font(.system(size: 10, weight: .medium))
                                                            .foregroundStyle(.green)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 8)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        // Expanded body
                                        if isActive {
                                            VStack(alignment: .leading, spacing: 10) {
                                                stepContent(for: step)
                                            }
                                            .padding(.bottom, 12)
                                            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                                        }

                                        if !isLast && !isActive {
                                            Divider().opacity(0.5)
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            .id(step.id)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .onChange(of: activeStep) { idx in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(steps[min(idx, steps.count - 1)].id, anchor: .center)
                    }
                }
            }

            // Footer
            Divider()
            HStack {
                if activeStep > 0 && !allDone {
                    Button("Back") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { activeStep -= 1 }
                    }
                }

                Spacer()

                if allDone {
                    Button(action: onComplete) {
                        Text("Get Started")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    if steps[activeStep].skippable {
                        Button("Skip") {
                            skippedSteps.insert(steps[activeStep])
                            advanceFrom(activeStep)
                        }
                        .foregroundStyle(.secondary)
                    }

                    Button("Continue") { advanceFrom(activeStep) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 540)
        .onAppear {
            apiKeyInput = appState.apiKey
            customVocabularyInput = appState.customVocabulary
            checkMicPermission()
            accessibilityGranted = AXIsProcessTrusted()
            appState.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
            startAccessibilityPolling()
            startScreenRecordingPolling()
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            screenRecordingTimer?.invalidate()
            screenRecordingTimer = nil
            // Don't call stopTestHotkeyMonitoring() here — completeSetup()
            // already called startHotkeyMonitoring() which we must not override.
            // The test step's own onDisappear handles cleanup when navigating away.
        }
        .onChange(of: appState.selectedTranscriptionProvider) { _ in
            // When provider changes, clamp activeStep so it doesn't point past the new steps array
            clampActiveStep()
        }
    }

    // MARK: - Step Circle

    @ViewBuilder
    private func stepCircle(index: Int, isDone: Bool, isActive: Bool, isSkipped: Bool = false) -> some View {
        ZStack {
            if isDone && isSkipped {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 22, height: 22)
                Image(systemName: "forward.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            } else if isDone {
                Circle()
                    .fill(Color.green)
                    .frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else if isActive {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private func stepContent(for step: SetupStep) -> some View {
        switch step {
        case .transcriptionProvider: transcriptionContent
        case .apiKey: apiKeyContent
        case .micPermission: micPermissionContent
        case .accessibility: accessibilityContent
        case .screenRecording: screenRecordingContent
        case .hotkey: hotkeyContent
        case .vocabulary: vocabularyContent
        case .launchAtLogin: launchAtLoginContent
        case .testTranscription: testTranscriptionContent
        }
    }

    // MARK: - Transcription

    private var transcriptionContent: some View {
        VStack(spacing: 6) {
            providerOption(.local, icon: "desktopcomputer", title: "Local (Parakeet)", subtitle: "On-device. No internet needed.")
            providerOption(.groq, icon: "cloud", title: "Groq (Whisper)", subtitle: "Fast cloud transcription. Requires key.")
        }
    }

    private func providerOption(_ provider: TranscriptionProvider, icon: String, title: String, subtitle: String) -> some View {
        let on = appState.selectedTranscriptionProvider == provider
        return Button { appState.selectedTranscriptionProvider = provider } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.3))
                    .font(.system(size: 14))
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(on ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - API Key

    private var apiKeyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Required for Groq cloud transcription. Also enables post-processing.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            SecureField("gsk_...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disabled(isValidatingKey)
                .onChange(of: apiKeyInput) { _ in keyValidationError = nil }

            if let error = keyValidationError {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Permissions

    private var micPermissionContent: some View {
        permissionRow(
            description: "Required to record audio for transcription.",
            granted: micPermissionGranted,
            action: { requestMicPermission() }
        )
    }

    private var accessibilityContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(
                description: "Required to paste transcribed text into apps.",
                granted: accessibilityGranted,
                action: { requestAccessibility() },
                buttonLabel: "Open Settings"
            )
            if !accessibilityGranted {
                Text("If you rebuilt the app, remove and re-add it in Accessibility settings.")
                    .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.6))

                #if DEBUG
                Button {
                    let bundlePath = Bundle.main.bundleURL.path
                    // Use /bin/sh -c with sleep to relaunch after this process exits
                    let script = "sleep 0.5; open \"\(bundlePath)\""
                    Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", script])
                    NSApp.terminate(nil)
                } label: {
                    Label("Restart App", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                #endif
            }
        }
    }

    private var screenRecordingContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(
                description: "Captures context for smarter post-processing.",
                granted: appState.hasScreenRecordingPermission,
                action: { appState.requestScreenCapturePermission() }
            )
        }
    }

    private func permissionRow(description: String, granted: Bool, action: @escaping () -> Void, buttonLabel: String = "Grant Access") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(description)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                } else {
                    Button(buttonLabel, action: action)
                        .font(.system(size: 11))
                }
            }
        }
    }

    // MARK: - Hotkey

    private var hotkeyContent: some View {
        VStack(spacing: 4) {
            ForEach(HotkeyOption.allCases) { option in
                HotkeyOptionRow(
                    option: option,
                    isSelected: appState.selectedHotkey == option,
                    action: { appState.selectedHotkey = option }
                )
            }
            if appState.selectedHotkey == .fnKey {
                Text("Tip: If Fn opens Emoji picker, change \"Press fn key to\" to \"Do Nothing\" in System Settings.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Vocabulary

    private var vocabularyContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $customVocabularyInput)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 50)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))

            Text("Comma, newline, or semicolon separated.")
                .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.6))
        }
    }

    // MARK: - Launch at Login

    private var launchAtLoginContent: some View {
        Toggle("Start Wrenflow when you log in", isOn: $appState.launchAtLogin)
            .font(.system(size: 12))
    }

    // MARK: - Test Transcription

    private var testTranscriptionContent: some View {
        VStack(spacing: 8) {
            switch testPhase {
            case .idle:
                VStack(spacing: 4) {
                    Text("Hold **\(appState.selectedHotkey.displayName)** and say something.")
                        .font(.system(size: 12))
                    Text("Release to transcribe.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .recording:
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("Listening...").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                }
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing...").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .done:
                if let error = testError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.red)
                } else if testTranscript.isEmpty {
                    Label("No speech detected. Try again.", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Success", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        Text(testTranscript)
                            .font(.system(size: 11))
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(5)
                    }
                }
            }
        }
        .onAppear { startTestHotkeyMonitoring() }
        .onDisappear { stopTestHotkeyMonitoring() }
    }

    // MARK: - Navigation

    /// Clamp activeStep to be valid for the current steps array.
    /// Called when provider changes, which can add/remove the API key step.
    private func clampActiveStep() {
        if activeStep > steps.count {
            activeStep = steps.count
        }
    }

    private func advanceFrom(_ index: Int) {
        let step = steps[index]
        switch step {
        case .apiKey:
            let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !isValidatingKey {
                validateAndContinue(from: index)
                return
            }
        case .transcriptionProvider:
            if appState.selectedTranscriptionProvider == .local {
                appState.localTranscriptionService.initialize()
            }
        case .vocabulary:
            appState.customVocabulary = customVocabularyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        case .testTranscription:
            stopTestHotkeyMonitoring()
        default: break
        }

        goNext(from: index)
    }

    private func validateAndContinue(from index: Int) {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { goNext(from: index); return }
        isValidatingKey = true
        keyValidationError = nil
        Task {
            let valid = await PostProcessingService.validateAPIKey(key, baseURL: appState.apiBaseURL)
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    goNext(from: index)
                } else {
                    keyValidationError = "Invalid API key."
                }
            }
        }
    }

    private func goNext(from index: Int) {
        let next = index + 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            activeStep = next  // If next >= steps.count, allDone becomes true
        }
    }

    // MARK: - Helpers

    private func checkMicPermission() { micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micPermissionGranted = granted }
        }
    }

    private func requestAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { accessibilityGranted = AXIsProcessTrusted() }
        }
    }

    private func startScreenRecordingPolling() {
        screenRecordingTimer?.invalidate()
        screenRecordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { appState.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess() }
        }
    }

    private func startTestHotkeyMonitoring() {
        print("[SetupWizard] startTestHotkeyMonitoring called, starting hotkey: \(appState.selectedHotkey)")
        appState.hotkeyManager.start(option: appState.selectedHotkey)
        appState.hotkeyManager.onKeyDown = {
            DispatchQueue.main.async {
                print("[SetupWizard] onKeyDown fired, testPhase=\(testPhase)")
                guard testPhase == .idle || testPhase == .done else { return }
                if testPhase == .done { resetTest() }
                do {
                    let recorder = appState.audioRecorder
                    try recorder.startRecording(deviceUID: appState.selectedMicrophoneID)
                    testAudioLevelCancellable = recorder.$audioLevel.receive(on: DispatchQueue.main).sink { testAudioLevel = $0 }
                    print("[SetupWizard] Recording started")
                    withAnimation { testPhase = .recording }
                } catch {
                    print("[SetupWizard] Recording error: \(error)")
                    testError = error.localizedDescription
                    withAnimation { testPhase = .done }
                }
            }
        }
        appState.hotkeyManager.onKeyUp = {
            DispatchQueue.main.async {
                print("[SetupWizard] onKeyUp fired, testPhase=\(testPhase)")
                guard testPhase == .recording else { return }
                let recorder = appState.audioRecorder
                let result = recorder.stopRecording()
                testAudioLevelCancellable?.cancel(); testAudioLevel = 0
                withAnimation { testPhase = .transcribing }
                guard let url = result?.fileURL else {
                    print("[SetupWizard] No audio file from recorder")
                    testError = "No audio recorded."
                    withAnimation { testPhase = .done }; return
                }
                print("[SetupWizard] Transcribing \(url.lastPathComponent), model state: \(appState.localTranscriptionService.state)")
                Task {
                    do {
                        let t = try await appState.localTranscriptionService.transcribe(fileURL: url)
                        print("[SetupWizard] Transcription result: \(t.prefix(50))")
                        await MainActor.run { testTranscript = t; withAnimation { testPhase = .done } }
                    } catch {
                        await MainActor.run { testError = error.localizedDescription; withAnimation { testPhase = .done } }
                    }
                }
            }
        }
    }

    private func stopTestHotkeyMonitoring() {
        appState.hotkeyManager.stop()
        appState.hotkeyManager.onKeyDown = nil
        appState.hotkeyManager.onKeyUp = nil
    }
    private func resetTest() { testPhase = .idle; testTranscript = ""; testError = nil; testAudioLevel = 0 }
}
