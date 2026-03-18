import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - Shared Helpers

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(WrenflowStyle.title(13))
                .foregroundColor(WrenflowStyle.textSecondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WrenflowStyle.surface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(WrenflowStyle.border, lineWidth: 1)
        )
    }
}

private let iso8601DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 2) {
                // Space for traffic light buttons
                Spacer().frame(height: 12)

                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                                .foregroundColor(appState.selectedSettingsTab == tab
                                                 ? WrenflowStyle.text
                                                 : WrenflowStyle.textTertiary)
                                .frame(width: 16)
                            Text(tab.title)
                                .font(WrenflowStyle.body(13))
                                .foregroundColor(appState.selectedSettingsTab == tab
                                                 ? WrenflowStyle.text
                                                 : WrenflowStyle.textSecondary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(appState.selectedSettingsTab == tab
                                      ? WrenflowStyle.text.opacity(0.07)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // Branding at bottom of sidebar
                VStack(spacing: 4) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .opacity(0.5)
                    Text("Wrenflow")
                        .font(WrenflowStyle.body(11))
                        .foregroundColor(WrenflowStyle.textTertiary)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(WrenflowStyle.mono(10))
                        .foregroundColor(WrenflowStyle.textTertiary.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .padding(8)
            .frame(width: 150)
            .background(WrenflowStyle.bg)

            // Subtle divider
            Rectangle()
                .fill(WrenflowStyle.border)
                .frame(width: 1)

            // Content
            Group {
                switch appState.selectedSettingsTab {
                case .general, .none:
                    GeneralSettingsView()
                case .models:
                    ModelsSettingsView()
                case .aiCleanup:
                    AICleanupSettingsView()
                case .runLog:
                    RunLogView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WrenflowStyle.bg)
        }
        .environment(\.colorScheme, .light)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var micPermissionGranted = false
    @ObservedObject private var updateManager = UpdateManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsCard("Startup") {
                    startupSection
                }
                SettingsCard("Updates") {
                    updatesSection
                }
                SettingsCard("Push-to-Talk Key") {
                    hotkeySection
                }
                SettingsCard("Microphone") {
                    microphoneSection
                }
                SettingsCard("Permissions") {
                    permissionsSection
                }
                SettingsCard("CLI Tool") {
                    cliSection
                }
            }
            .padding(16)
        }
        .background(WrenflowStyle.bg)
        .onAppear {
            checkMicPermission()
            appState.refreshLaunchAtLoginStatus()
        }
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch Wrenflow at login", isOn: $appState.launchAtLogin)
                .font(WrenflowStyle.body(13))
                .foregroundColor(WrenflowStyle.text)
                .toggleStyle(.switch)
                .controlSize(.small)

            if SMAppService.mainApp.status == .requiresApproval {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                    Text("Login item requires approval in System Settings.")
                        .font(WrenflowStyle.caption(11))
                        .foregroundColor(WrenflowStyle.textSecondary)
                    Button("Open Login Items Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .font(WrenflowStyle.caption(11))
                }
            }
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updateManager.autoCheckEnabled },
                set: { updateManager.autoCheckEnabled = $0 }
            ))
            .font(WrenflowStyle.body(13))
            .foregroundColor(WrenflowStyle.text)
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    Task {
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    if updateManager.isChecking {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Checking...")
                                .font(WrenflowStyle.body(12))
                        }
                    } else {
                        Text("Check for Updates Now")
                            .font(WrenflowStyle.body(12))
                    }
                }
                .disabled(updateManager.isChecking || updateManager.updateStatus != .idle)

                if let lastCheck = updateManager.lastCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(WrenflowStyle.caption(11))
                        .foregroundColor(WrenflowStyle.textTertiary)
                }
            }

            if updateManager.updateAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    switch updateManager.updateStatus {
                    case .downloading:
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(WrenflowStyle.text.opacity(0.5))
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Downloading update...")
                                    .font(WrenflowStyle.body(12))
                                    .foregroundColor(WrenflowStyle.text)
                                WrenflowProgressBar(progress: updateManager.downloadProgress ?? 0)
                                if let progress = updateManager.downloadProgress {
                                    Text("\(Int(progress * 100))%")
                                        .font(WrenflowStyle.mono(11))
                                        .foregroundColor(WrenflowStyle.textSecondary)
                                }
                            }
                            Spacer()
                            Button("Cancel") {
                                updateManager.cancelDownload()
                            }
                            .font(WrenflowStyle.body(11))
                        }

                    case .installing:
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Installing update...")
                                .font(WrenflowStyle.body(12))
                                .foregroundColor(WrenflowStyle.text)
                        }

                    case .readyToRelaunch:
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Relaunching...")
                                .font(WrenflowStyle.body(12))
                                .foregroundColor(WrenflowStyle.text)
                        }

                    case .error(let message):
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(WrenflowStyle.red)
                                .font(.system(size: 10))
                            Text(message)
                                .font(WrenflowStyle.caption(11))
                                .foregroundColor(WrenflowStyle.red)
                            Spacer()
                            Button("Retry") {
                                updateManager.updateStatus = .idle
                                if let release = updateManager.latestRelease {
                                    updateManager.downloadAndInstall(release: release)
                                }
                            }
                            .font(WrenflowStyle.body(11))
                        }

                    case .idle:
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(WrenflowStyle.text.opacity(0.5))
                                .font(.system(size: 12))
                            Text("A new version of Wrenflow is available!")
                                .font(WrenflowStyle.body(12))
                                .foregroundColor(WrenflowStyle.text)
                            Spacer()
                            Button("Update Now") {
                                if let release = updateManager.latestRelease {
                                    updateManager.downloadAndInstall(release: release)
                                }
                            }
                            .font(WrenflowStyle.body(11))
                        }
                    }
                }
                .padding(8)
                .background(WrenflowStyle.text.opacity(0.04))
                .cornerRadius(6)
            }
        }
    }

    // MARK: CLI Tool

    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Control Wrenflow from the command line or a joystick app.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            HStack {
                if CLIInstaller.isInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(WrenflowStyle.green)
                            .font(.system(size: 10))
                        Text("Installed at \(CLIInstaller.installPath)")
                            .font(WrenflowStyle.caption(11))
                            .foregroundColor(WrenflowStyle.green)
                    }
                } else {
                    Text("Not installed")
                        .font(WrenflowStyle.caption(11))
                        .foregroundColor(WrenflowStyle.textSecondary)
                }

                Spacer()

                Button(CLIInstaller.isInstalled ? "Reinstall" : "Install to /usr/local/bin") {
                    CLIInstaller.install()
                }
                .font(WrenflowStyle.body(11))
                .controlSize(.small)
            }

            Text("Usage: wrenflow start | stop | toggle | status")
                .font(WrenflowStyle.mono(11))
                .foregroundColor(WrenflowStyle.textTertiary)
        }
    }

    // MARK: Push-to-Talk Key

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hold this key to record, release to transcribe.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            VStack(spacing: 4) {
                ForEach(HotkeyOption.allCases) { option in
                    HotkeyOptionRow(
                        option: option,
                        isSelected: appState.selectedHotkey == option,
                        action: {
                            appState.selectedHotkey = option
                        }
                    )
                }
            }

            if appState.selectedHotkey == .fnKey {
                Text("Tip: If Fn opens Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                    .font(WrenflowStyle.caption(11))
                    .foregroundColor(.orange)
            }

            Rectangle()
                .fill(WrenflowStyle.border)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum recording duration")
                        .font(WrenflowStyle.body(12))
                        .foregroundColor(WrenflowStyle.text)
                    Spacer()
                    Text("\(Int(appState.minimumRecordingDurationMs))ms")
                        .font(WrenflowStyle.mono(12))
                        .foregroundColor(WrenflowStyle.textSecondary)
                }
                Slider(value: $appState.minimumRecordingDurationMs, in: 50...500, step: 50)
                    .controlSize(.small)
                Text("Recordings shorter than this are treated as accidental and cancelled.")
                    .font(WrenflowStyle.caption(11))
                    .foregroundColor(WrenflowStyle.textTertiary)
            }
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select which microphone to use for recording.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            VStack(spacing: 4) {
                MicrophoneOptionRow(
                    name: "System Default",
                    isSelected: appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty,
                    action: { appState.selectedMicrophoneID = "default" }
                )
                ForEach(appState.availableMicrophones) { device in
                    MicrophoneOptionRow(
                        name: device.name,
                        isSelected: appState.selectedMicrophoneID == device.id,
                        action: { appState.selectedMicrophoneID = device.id }
                    )
                }
            }
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
        }
    }



    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(
                title: "Microphone",
                description: "Record audio for transcription",
                granted: micPermissionGranted,
                action: {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            micPermissionGranted = granted
                        }
                    }
                }
            )

            permissionRow(
                title: "Accessibility",
                description: "Paste transcribed text into apps",
                granted: appState.hasAccessibility,
                action: {
                    appState.openAccessibilitySettings()
                }
            )

            permissionRow(
                title: "Screen Recording",
                description: "Capture context for smarter AI cleanup",
                granted: appState.hasScreenRecordingPermission,
                action: {
                    appState.requestScreenCapturePermission()
                }
            )
        }
    }

    private func permissionRow(title: String, description: String = "", granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WrenflowStyle.body(12))
                    .foregroundColor(WrenflowStyle.text)
                if !description.isEmpty {
                    Text(description)
                        .font(WrenflowStyle.caption(11))
                        .foregroundColor(WrenflowStyle.textTertiary)
                }
            }
            Spacer()
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WrenflowStyle.green)
                        .font(.system(size: 10))
                    Text("Granted")
                        .font(WrenflowStyle.caption(11))
                        .foregroundColor(WrenflowStyle.green)
                }
            } else {
                Button("Grant Access") {
                    action()
                }
                .font(WrenflowStyle.body(11))
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(WrenflowStyle.bg)
        .cornerRadius(5)
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

}

// MARK: - Hotkey Option Row

struct HotkeyOptionRow: View {
    let option: HotkeyOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(option.displayName)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Microphone Option Row

struct MicrophoneOptionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? WrenflowStyle.text : WrenflowStyle.textTertiary)
                    .font(.system(size: 12))
                Text(name)
                    .font(WrenflowStyle.body(12))
                    .foregroundColor(WrenflowStyle.text)
                Spacer()
            }
            .padding(8)
            .background(isSelected ? WrenflowStyle.text.opacity(0.05) : WrenflowStyle.bg)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? WrenflowStyle.text.opacity(0.15) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Models Settings

struct ModelsSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsCard("Local Transcription") {
                    localTranscriptionSection
                }
            }
            .padding(16)
        }
        .background(WrenflowStyle.bg)
    }

    private var localTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-device speech recognition using Parakeet TDT.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            switch appState.localTranscriptionService.state {
            case .notLoaded:
                HStack {
                    Text("Model not downloaded")
                        .font(WrenflowStyle.body(12))
                        .foregroundColor(WrenflowStyle.textSecondary)
                    Spacer()
                    Button("Download") {
                        appState.localTranscriptionService.initialize()
                    }
                    .font(WrenflowStyle.body(12))
                }

            case .downloading(let info):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading...")
                            .font(WrenflowStyle.body(12))
                            .foregroundColor(WrenflowStyle.textSecondary)
                        Spacer()
                        Text(settingsDownloadStatus(info))
                            .font(WrenflowStyle.mono(11))
                            .foregroundColor(WrenflowStyle.textTertiary)
                    }
                    WrenflowProgressBar(progress: min(info.fraction, 1.0))
                    Button("Cancel") {
                        appState.localTranscriptionService.cancel()
                    }
                    .font(WrenflowStyle.body(11))
                    .foregroundColor(WrenflowStyle.textSecondary)
                }

            case .compiling:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Loading model...")
                        .font(WrenflowStyle.body(12))
                        .foregroundColor(WrenflowStyle.textSecondary)
                }

            case .ready:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WrenflowStyle.green)
                        .font(.system(size: 11))
                    Text("Ready")
                        .font(WrenflowStyle.body(12))
                        .foregroundColor(WrenflowStyle.green)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(WrenflowStyle.red)
                            .font(.system(size: 11))
                        Text(message)
                            .font(WrenflowStyle.caption(11))
                            .foregroundColor(WrenflowStyle.red)
                            .lineLimit(2)
                    }
                    Button("Retry") {
                        appState.localTranscriptionService.initialize()
                    }
                    .font(WrenflowStyle.body(11))
                }
            }
        }
    }

    private func settingsDownloadStatus(_ info: DownloadProgressInfo) -> String {
        let mbDown = Int(info.bytesDownloaded / 1_000_000)
        if let total = info.totalBytes {
            let mbTotal = Int(total / 1_000_000)
            let pct = min(Int(info.fraction * 100), 100)
            return "\(mbDown)/\(mbTotal) MB · \(pct)%"
        } else if mbDown > 0 {
            return "\(mbDown) MB"
        }
        return "0%"
    }
}

// MARK: - AI Cleanup Settings

struct AICleanupSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var apiBaseURLInput: String = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var keyValidationSuccess = false
    @State private var availableModels: [GroqModel] = []
    @State private var isFetchingModels = false
    @State private var modelFetchFailed = false
    @State private var customVocabularyInput: String = ""
    @State private var customSystemPromptInput: String = ""
    @State private var customContextPromptInput: String = ""
    @State private var showDefaultSystemPrompt = false
    @State private var showDefaultContextPrompt = false

    // System prompt test state
    @State private var systemTestInput: String = "Um, so I was like, thinking we should uh, refactor the authentication module, you know?"
    @State private var systemTestRunning = false
    @State private var systemTestOutput: String? = nil
    @State private var systemTestError: String? = nil
    @State private var systemTestPrompt: String? = nil

    // Context prompt test state
    @State private var contextTestRunning = false
    @State private var contextTestOutput: String? = nil
    @State private var contextTestError: String? = nil
    @State private var contextTestPrompt: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsCard("AI Cleanup") {
                    postProcessingToggleSection
                }
                SettingsCard("API Key") {
                    apiKeySection
                }
                if !appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && appState.postProcessingEnabled {
                    SettingsCard("Post-Processing Model") {
                        postProcessingModelSection
                    }
                }
                SettingsCard("System Prompt") {
                    systemPromptSection
                }
                SettingsCard("Custom Vocabulary") {
                    vocabularySection
                }
                SettingsCard("Context Prompt") {
                    contextPromptSection
                }
            }
            .padding(16)
        }
        .background(WrenflowStyle.bg)
        .onAppear {
            apiKeyInput = appState.apiKey
            customVocabularyInput = appState.customVocabulary
            apiBaseURLInput = appState.apiBaseURL
            customSystemPromptInput = appState.customSystemPrompt.isEmpty
                ? PostProcessingService.defaultSystemPrompt
                : appState.customSystemPrompt
            customContextPromptInput = appState.customContextPrompt.isEmpty
                ? AppContextService.defaultContextPrompt
                : appState.customContextPrompt
        }
    }

    // MARK: Toggle

    private var postProcessingToggleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable LLM post-processing", isOn: $appState.postProcessingEnabled)
                .font(WrenflowStyle.body(13))
                .foregroundColor(WrenflowStyle.text)
                .toggleStyle(.switch)
                .controlSize(.small)
            Text("When enabled, an LLM cleans up transcriptions using screen context. When disabled, raw transcription is pasted directly.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)
        }
    }

    // MARK: API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Used for LLM post-processing (text cleanup).")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            HStack(spacing: 6) {
                SecureField("Enter your API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(WrenflowStyle.mono(12))
                    .controlSize(.small)
                    .disabled(isValidatingKey)
                    .onChange(of: apiKeyInput) { _ in
                        keyValidationError = nil
                        keyValidationSuccess = false
                    }

                Button(isValidatingKey ? "Validating..." : "Save") {
                    validateAndSaveKey()
                }
                .font(WrenflowStyle.body(12))
                .controlSize(.small)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
            }

            if let error = keyValidationError {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                    Text(error)
                        .font(WrenflowStyle.caption(11))
                }
                .foregroundColor(WrenflowStyle.red)
            } else if keyValidationSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("API key saved")
                        .font(WrenflowStyle.caption(11))
                }
                .foregroundColor(WrenflowStyle.green)
            }

            Rectangle()
                .fill(WrenflowStyle.border)
                .frame(height: 1)

            Text("API Base URL")
                .font(WrenflowStyle.body(12))
                .foregroundColor(WrenflowStyle.text)

            Text("Change this to use a different OpenAI-compatible API provider.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            HStack(spacing: 6) {
                TextField("https://api.groq.com/openai/v1", text: $apiBaseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(WrenflowStyle.mono(12))
                    .controlSize(.small)
                    .onChange(of: apiBaseURLInput) { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            appState.apiBaseURL = trimmed
                        }
                    }

                Button("Reset to Default") {
                    apiBaseURLInput = "https://api.groq.com/openai/v1"
                    appState.apiBaseURL = "https://api.groq.com/openai/v1"
                }
                .font(WrenflowStyle.body(11))
                .controlSize(.small)
            }
        }
    }

    private func validateAndSaveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidatingKey = true
        keyValidationError = nil
        keyValidationSuccess = false

        Task {
            let valid = await PostProcessingService.validateAPIKey(key, baseURL: baseURL.isEmpty ? "https://api.groq.com/openai/v1" : baseURL)
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    keyValidationSuccess = true
                } else {
                    keyValidationError = "Invalid API key. Please check and try again."
                }
            }
        }
    }

    // MARK: Post-Processing Model

    private var postProcessingModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The LLM used to clean up raw transcriptions.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            if isFetchingModels {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Loading models...")
                        .font(WrenflowStyle.body(12))
                        .foregroundColor(WrenflowStyle.textSecondary)
                }
            } else if !availableModels.isEmpty {
                Picker("Model", selection: $appState.postProcessingModel) {
                    ForEach(availableModels) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    TextField("Model ID", text: $appState.postProcessingModel)
                        .textFieldStyle(.roundedBorder)
                        .font(WrenflowStyle.mono(12))
                        .controlSize(.small)

                    Button("Fetch Models") {
                        fetchModels()
                    }
                    .font(WrenflowStyle.body(11))
                    .controlSize(.small)
                }

                if modelFetchFailed {
                    Text("Could not load model list. You can type a model ID manually.")
                        .font(WrenflowStyle.caption(11))
                        .foregroundColor(WrenflowStyle.textTertiary)
                }
            }
        }
        .onAppear {
            if availableModels.isEmpty && !appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fetchModels()
            }
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        modelFetchFailed = false
        Task {
            let models = await GroqModelsService.fetchModels(apiKey: appState.apiKey, baseURL: appState.apiBaseURL)
            await MainActor.run {
                isFetchingModels = false
                if models.isEmpty {
                    modelFetchFailed = true
                } else {
                    availableModels = models
                }
            }
        }
    }

    // MARK: Custom Vocabulary

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Words and phrases to preserve during post-processing.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            TextEditor(text: $customVocabularyInput)
                .font(WrenflowStyle.mono(12))
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(WrenflowStyle.border, lineWidth: 1)
                )
                .onChange(of: customVocabularyInput) { newValue in
                    appState.customVocabulary = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }

            Text("Separate entries with commas, new lines, or semicolons.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)
        }
    }

    // MARK: System Prompt

    private var systemPromptSection: some View {
        let isCustom = !appState.customSystemPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customSystemPromptLastModified.isEmpty
            && appState.customSystemPromptLastModified < PostProcessingService.defaultSystemPromptDate

        return VStack(alignment: .leading, spacing: 8) {
            Text("Controls how raw transcriptions are cleaned up.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            if hasNewerDefault {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(WrenflowStyle.text.opacity(0.5))
                        .font(.system(size: 11))
                    Text("A newer default prompt is available.")
                        .font(WrenflowStyle.body(12))
                        .foregroundColor(WrenflowStyle.text)
                    Spacer()
                    Button("View Default") {
                        showDefaultSystemPrompt.toggle()
                    }
                    .font(WrenflowStyle.body(11))
                    Button("Switch to Default") {
                        customSystemPromptInput = PostProcessingService.defaultSystemPrompt
                        appState.customSystemPrompt = ""
                        appState.customSystemPromptLastModified = ""
                    }
                    .font(WrenflowStyle.body(11))
                }
                .padding(8)
                .background(WrenflowStyle.text.opacity(0.04))
                .cornerRadius(6)
            }

            if showDefaultSystemPrompt {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Default System Prompt")
                            .font(WrenflowStyle.body(12))
                            .foregroundColor(WrenflowStyle.text)
                        Spacer()
                        Button("Hide") {
                            showDefaultSystemPrompt = false
                        }
                        .font(WrenflowStyle.body(11))
                    }
                    Text(PostProcessingService.defaultSystemPrompt)
                        .font(WrenflowStyle.mono(11))
                        .foregroundColor(WrenflowStyle.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(WrenflowStyle.bg)
                .cornerRadius(6)
            }

            TextEditor(text: $customSystemPromptInput)
                .font(WrenflowStyle.mono(12))
                .frame(minHeight: 100, maxHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(WrenflowStyle.border, lineWidth: 1)
                )
                .onChange(of: customSystemPromptInput) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaultTrimmed = PostProcessingService.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == defaultTrimmed || trimmed.isEmpty {
                        if !appState.customSystemPrompt.isEmpty {
                            appState.customSystemPrompt = ""
                            appState.customSystemPromptLastModified = ""
                        }
                    } else {
                        appState.customSystemPrompt = trimmed
                        let today = iso8601DayFormatter.string(from: Date())
                        if appState.customSystemPromptLastModified != today {
                            appState.customSystemPromptLastModified = today
                        }
                    }
                }

            HStack {
                if isCustom {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                        Text("Using custom prompt")
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(WrenflowStyle.text.opacity(0.6))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                        Text("Using default")
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(WrenflowStyle.textTertiary)
                }
                Spacer()
                if isCustom {
                    Button("Reset to Default") {
                        customSystemPromptInput = PostProcessingService.defaultSystemPrompt
                        appState.customSystemPrompt = ""
                        appState.customSystemPromptLastModified = ""
                    }
                    .font(WrenflowStyle.body(11))
                }
            }

            Rectangle()
                .fill(WrenflowStyle.border)
                .frame(height: 1)

            // Test section
            VStack(alignment: .leading, spacing: 6) {
                Text("Test System Prompt")
                    .font(WrenflowStyle.body(12))
                    .foregroundColor(WrenflowStyle.text)
                Text("Enter sample text to see how the current prompt cleans it up.")
                    .font(WrenflowStyle.caption(11))
                    .foregroundColor(WrenflowStyle.textTertiary)

                TextEditor(text: $systemTestInput)
                    .font(WrenflowStyle.mono(12))
                    .frame(minHeight: 50, maxHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(WrenflowStyle.border, lineWidth: 1)
                    )

                Button {
                    runSystemPromptTest()
                } label: {
                    HStack(spacing: 4) {
                        if systemTestRunning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Running...")
                                .font(WrenflowStyle.body(12))
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Test System Prompt")
                                .font(WrenflowStyle.body(12))
                        }
                    }
                }
                .disabled(systemTestRunning || appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || systemTestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text("API key required to test")
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(.orange)
                }

                if let error = systemTestError {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                        Text(error)
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(WrenflowStyle.red)
                }

                if let output = systemTestOutput {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Result:")
                            .font(WrenflowStyle.body(12))
                            .foregroundColor(WrenflowStyle.text)
                        Text(output.isEmpty ? "(empty -- no output)" : output)
                            .font(WrenflowStyle.mono(11))
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WrenflowStyle.green.opacity(0.08))
                            .cornerRadius(5)
                    }
                }

                if let prompt = systemTestPrompt {
                    DisclosureGroup("Full prompt sent") {
                        Text(prompt)
                            .font(WrenflowStyle.mono(10))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(WrenflowStyle.caption(11))
                    .foregroundColor(WrenflowStyle.textSecondary)
                }
            }
        }
    }

    private func runSystemPromptTest() {
        systemTestRunning = true
        systemTestOutput = nil
        systemTestError = nil
        systemTestPrompt = nil

        let service = PostProcessingService(apiKey: appState.apiKey, baseURL: appState.apiBaseURL, model: appState.postProcessingModel)
        let input = systemTestInput
        let customPrompt = appState.customSystemPrompt
        let vocabulary = appState.customVocabulary

        let context = AppContext(
            appName: "Wrenflow Settings",
            bundleIdentifier: "me.gulya.wrenflow",
            windowTitle: "System Prompt Test",
            selectedText: nil,
            currentActivity: "User is testing the system prompt in Wrenflow settings.",
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: nil,
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

        Task {
            do {
                let result = try await service.postProcess(
                    transcript: input,
                    context: context,
                    customVocabulary: vocabulary,
                    customSystemPrompt: customPrompt
                )
                await MainActor.run {
                    systemTestOutput = result.transcript
                    systemTestPrompt = result.prompt
                    systemTestRunning = false
                }
            } catch {
                await MainActor.run {
                    systemTestError = error.localizedDescription
                    systemTestRunning = false
                }
            }
        }
    }

    // MARK: Context Prompt

    private var contextPromptSection: some View {
        let isCustom = !appState.customContextPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customContextPromptLastModified.isEmpty
            && appState.customContextPromptLastModified < AppContextService.defaultContextPromptDate

        return VStack(alignment: .leading, spacing: 8) {
            Text("Controls how Wrenflow infers your current activity from app metadata and screenshots.")
                .font(WrenflowStyle.caption(11))
                .foregroundColor(WrenflowStyle.textTertiary)

            if hasNewerDefault {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(WrenflowStyle.text.opacity(0.5))
                        .font(.system(size: 11))
                    Text("A newer default prompt is available.")
                        .font(WrenflowStyle.body(12))
                        .foregroundColor(WrenflowStyle.text)
                    Spacer()
                    Button("View Default") {
                        showDefaultContextPrompt.toggle()
                    }
                    .font(WrenflowStyle.body(11))
                    Button("Switch to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(WrenflowStyle.body(11))
                }
                .padding(8)
                .background(WrenflowStyle.text.opacity(0.04))
                .cornerRadius(6)
            }

            if showDefaultContextPrompt {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Default Context Prompt")
                            .font(WrenflowStyle.body(12))
                            .foregroundColor(WrenflowStyle.text)
                        Spacer()
                        Button("Hide") {
                            showDefaultContextPrompt = false
                        }
                        .font(WrenflowStyle.body(11))
                    }
                    Text(AppContextService.defaultContextPrompt)
                        .font(WrenflowStyle.mono(11))
                        .foregroundColor(WrenflowStyle.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(WrenflowStyle.bg)
                .cornerRadius(6)
            }

            TextEditor(text: $customContextPromptInput)
                .font(WrenflowStyle.mono(12))
                .frame(minHeight: 100, maxHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(WrenflowStyle.border, lineWidth: 1)
                )
                .onChange(of: customContextPromptInput) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaultTrimmed = AppContextService.defaultContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == defaultTrimmed || trimmed.isEmpty {
                        if !appState.customContextPrompt.isEmpty {
                            appState.customContextPrompt = ""
                            appState.customContextPromptLastModified = ""
                        }
                    } else {
                        appState.customContextPrompt = trimmed
                        let today = iso8601DayFormatter.string(from: Date())
                        if appState.customContextPromptLastModified != today {
                            appState.customContextPromptLastModified = today
                        }
                    }
                }

            HStack {
                if isCustom {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                        Text("Using custom prompt")
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(WrenflowStyle.text.opacity(0.6))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                        Text("Using default")
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(WrenflowStyle.textTertiary)
                }
                Spacer()
                if isCustom {
                    Button("Reset to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(WrenflowStyle.body(11))
                }
            }

            Rectangle()
                .fill(WrenflowStyle.border)
                .frame(height: 1)

            // Test section
            VStack(alignment: .leading, spacing: 6) {
                Text("Test Context Prompt")
                    .font(WrenflowStyle.body(12))
                    .foregroundColor(WrenflowStyle.text)
                Text("Captures a screenshot and metadata from the frontmost app, then runs the context prompt to infer activity.")
                    .font(WrenflowStyle.caption(11))
                    .foregroundColor(WrenflowStyle.textTertiary)

                Button {
                    runContextPromptTest()
                } label: {
                    HStack(spacing: 4) {
                        if contextTestRunning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Running...")
                                .font(WrenflowStyle.body(12))
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Test Context Prompt")
                                .font(WrenflowStyle.body(12))
                        }
                    }
                }
                .disabled(contextTestRunning || appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text("API key required to test")
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(.orange)
                }

                if let error = contextTestError {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                        Text(error)
                            .font(WrenflowStyle.caption(11))
                    }
                    .foregroundColor(WrenflowStyle.red)
                }

                if let output = contextTestOutput {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Result:")
                            .font(WrenflowStyle.body(12))
                            .foregroundColor(WrenflowStyle.text)
                        Text(output.isEmpty ? "(empty -- no output)" : output)
                            .font(WrenflowStyle.mono(11))
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WrenflowStyle.green.opacity(0.08))
                            .cornerRadius(5)
                    }
                }

                if let prompt = contextTestPrompt {
                    DisclosureGroup("Full prompt sent") {
                        Text(prompt)
                            .font(WrenflowStyle.mono(10))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(WrenflowStyle.caption(11))
                    .foregroundColor(WrenflowStyle.textSecondary)
                }
            }
        }
    }

    private func runContextPromptTest() {
        contextTestRunning = true
        contextTestOutput = nil
        contextTestError = nil
        contextTestPrompt = nil

        let service = AppContextService(
            apiKey: appState.apiKey,
            baseURL: appState.apiBaseURL,
            customContextPrompt: appState.customContextPrompt
        )

        Task {
            let context = await service.collectContext()
            await MainActor.run {
                if let prompt = context.contextPrompt {
                    contextTestOutput = context.contextSummary
                    contextTestPrompt = prompt
                } else {
                    contextTestError = "Context inference returned no result. This may be a permissions issue or the API could not be reached."
                    contextTestOutput = context.contextSummary
                }
                contextTestRunning = false
            }
        }
    }
}

// MARK: - GitHub Metadata

struct GitHubRepoInfo: Decodable {
    let stargazersCount: Int

    private enum CodingKeys: String, CodingKey {
        case stargazersCount = "stargazers_count"
    }
}

struct GitHubStarRecord: Decodable, Identifiable {
    let user: GitHubStarUser

    var id: Int {
        user.id
    }
}

struct GitHubStarUser: Decodable {
    let id: Int
    let login: String
    let avatarUrl: URL
    let htmlUrl: URL

    /// Avatar URL resized to 44px (2x for 22pt display) for efficient loading
    var avatarThumbnailUrl: URL {
        let separator = avatarUrl.absoluteString.contains("?") ? "&" : "?"
        return URL(string: avatarUrl.absoluteString + "\(separator)s=44") ?? avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case avatarUrl = "avatar_url"
        case htmlUrl = "html_url"
    }
}

@MainActor
class GitHubMetadataCache: ObservableObject {
    static let shared = GitHubMetadataCache()

    @Published var starCount: Int?
    @Published var recentStargazers: [GitHubStarRecord] = []
    @Published var isLoading = true

    private var lastFetchDate: Date?
    private let cacheDuration: TimeInterval = 5 * 60 // 5 minutes
    private let repoAPIURL = URL(string: "https://api.github.com/repos/IlyaGulya/wrenflow")!

    private init() {}

    func fetchIfNeeded() async {
        if let lastFetch = lastFetchDate, Date().timeIntervalSince(lastFetch) < cacheDuration {
            return
        }

        isLoading = true

        do {
            let repoResult = try await URLSession.shared.data(from: repoAPIURL)
            guard let repoHTTP = repoResult.1 as? HTTPURLResponse,
                  (200..<300).contains(repoHTTP.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let count = try JSONDecoder().decode(GitHubRepoInfo.self, from: repoResult.0).stargazersCount

            var recent: [GitHubStarRecord] = []
            if count > 0 {
                let perPage = 100
                let lastPage = max(1, Int(ceil(Double(count) / Double(perPage))))
                let stargazersURL = URL(string: "https://api.github.com/repos/IlyaGulya/wrenflow/stargazers?per_page=\(perPage)&page=\(lastPage)")!
                var request = URLRequest(url: stargazersURL)
                request.setValue("application/vnd.github.v3.star+json", forHTTPHeaderField: "Accept")
                let starredResult = try await URLSession.shared.data(for: request)
                if let starredHTTP = starredResult.1 as? HTTPURLResponse,
                   (200..<300).contains(starredHTTP.statusCode) {
                    let all = try JSONDecoder().decode([GitHubStarRecord].self, from: starredResult.0)
                    recent = Array(all.suffix(15).reversed())
                }
            }

            starCount = count
            recentStargazers = recent
            isLoading = false
            lastFetchDate = Date()
        } catch {
            isLoading = false
        }
    }
}

// MARK: - Run Log

struct RunLogView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Log")
                        .font(WrenflowStyle.title(14))
                        .foregroundColor(WrenflowStyle.text)
                    Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent runs are kept.")
                        .font(WrenflowStyle.caption(11))
                        .foregroundColor(WrenflowStyle.textTertiary)
                }
                Spacer()
                Button("Clear History") {
                    appState.clearPipelineHistory()
                }
                .font(WrenflowStyle.body(11))
                .controlSize(.small)
                .disabled(appState.pipelineHistory.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle()
                .fill(WrenflowStyle.border)
                .frame(height: 1)

            if appState.pipelineHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No runs yet. Use dictation to populate history.")
                        .font(WrenflowStyle.body(13))
                        .foregroundColor(WrenflowStyle.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.pipelineHistory) { item in
                            RunLogEntryView(item: item)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(WrenflowStyle.bg)
    }
}

// MARK: - Run Log Entry

struct RunLogEntryView: View {
    let item: PipelineHistoryItem
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false
    @State private var showContextPrompt = false
    @State private var showPostProcessingPrompt = false
    @State private var showAllMetrics = false

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        if isError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(WrenflowStyle.red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(item.timestamp.formatted(date: .numeric, time: .standard))
                                    .font(WrenflowStyle.body(12))
                                    .foregroundColor(WrenflowStyle.text)
                                if let total = item.metrics.double("pipeline.totalMs") {
                                    Text(formatDurationMs(total))
                                        .font(WrenflowStyle.mono(10))
                                        .foregroundColor(WrenflowStyle.textTertiary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(WrenflowStyle.text.opacity(0.05))
                                        .cornerRadius(3)
                                }
                            }
                            Text(item.postProcessedTranscript.isEmpty ? "(no transcript)" : item.postProcessedTranscript)
                                .font(WrenflowStyle.caption(11))
                                .foregroundColor(WrenflowStyle.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(WrenflowStyle.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.deleteHistoryEntry(id: item.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(WrenflowStyle.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this run")
            }
            .padding(10)

            if isExpanded {
                Rectangle()
                    .fill(WrenflowStyle.border)
                    .frame(height: 1)
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 12) {
                    // Audio player
                    if let audioFileName = item.audioFileName {
                        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
                        AudioPlayerView(audioURL: audioURL)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.slash")
                                .font(.system(size: 10))
                                .foregroundColor(WrenflowStyle.textTertiary)
                            Text("No audio recorded")
                                .font(WrenflowStyle.caption(11))
                                .foregroundColor(WrenflowStyle.textTertiary)
                        }
                    }

                    // Custom vocabulary
                    if !item.customVocabulary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Vocabulary")
                                .font(WrenflowStyle.body(11))
                                .foregroundColor(WrenflowStyle.textSecondary)
                            FlowLayout(spacing: 3) {
                                ForEach(parseVocabulary(item.customVocabulary), id: \.self) { word in
                                    Text(word)
                                        .font(WrenflowStyle.mono(10))
                                        .foregroundColor(WrenflowStyle.text)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(WrenflowStyle.text.opacity(0.05))
                                        .cornerRadius(3)
                                }
                            }
                        }
                    }

                    // Pipeline steps
                    VStack(alignment: .leading, spacing: 8) {
                        let ppEnabled = item.metrics.bool("postProcessing.enabled") == true

                        Text("Pipeline")
                            .font(WrenflowStyle.body(11))
                            .foregroundColor(WrenflowStyle.textSecondary)

                        // Recording
                        PipelineStepView(
                            number: 1,
                            title: "Record Audio",
                            durationMs: item.metrics.double("recording.durationMs"),
                            content: {
                                VStack(alignment: .leading, spacing: 3) {
                                    if let size = item.metrics.int("recording.fileSizeBytes") {
                                        Text("File size: \(formatFileSize(Int64(size)))")
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textSecondary)
                                    }
                                    if let reused = item.metrics.bool("engine.reused") {
                                        Text("Engine: \(reused ? "reused" : "new")")
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textSecondary)
                                    }
                                    if let initMs = item.metrics.double("engine.initMs") {
                                        Text("Engine init: \(formatDurationMs(initMs))")
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textSecondary)
                                    }
                                    if let firstMs = item.metrics.double("engine.firstBufferMs") {
                                        Text("First buffer: \(formatDurationMs(firstMs))")
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textSecondary)
                                    }
                                }
                            }
                        )

                        // Context Capture (hidden when post-processing disabled)
                        if ppEnabled {
                        PipelineStepView(
                            number: 2,
                            title: "Capture Context",
                            durationMs: item.metrics.double("context.totalMs") ?? item.metrics.double("context.resolutionMs"),
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if item.metrics.double("context.screenshotMs") != nil || item.metrics.double("context.llmMs") != nil {
                                        HStack(spacing: 10) {
                                            if let screenshotMs = item.metrics.double("context.screenshotMs") {
                                                HStack(spacing: 2) {
                                                    Text("Screenshot:")
                                                        .font(WrenflowStyle.mono(10))
                                                        .foregroundColor(WrenflowStyle.textTertiary)
                                                    Text(formatDurationMs(screenshotMs))
                                                        .font(WrenflowStyle.mono(10))
                                                        .foregroundColor(WrenflowStyle.textSecondary)
                                                }
                                            }
                                            if let llmMs = item.metrics.double("context.llmMs") {
                                                HStack(spacing: 2) {
                                                    Text("LLM:")
                                                        .font(WrenflowStyle.mono(10))
                                                        .foregroundColor(WrenflowStyle.textTertiary)
                                                    Text(formatDurationMs(llmMs))
                                                        .font(WrenflowStyle.mono(10))
                                                        .foregroundColor(WrenflowStyle.textSecondary)
                                                }
                                            }
                                        }
                                    }

                                    if let dataURL = item.contextScreenshotDataURL,
                                       let image = imageFromDataURL(dataURL) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 100)
                                            .cornerRadius(4)
                                    }

                                    if let prompt = item.contextPrompt, !prompt.isEmpty {
                                        Button {
                                            showContextPrompt.toggle()
                                        } label: {
                                            HStack(spacing: 3) {
                                                Text(showContextPrompt ? "Hide Prompt" : "Show Prompt")
                                                    .font(WrenflowStyle.caption(11))
                                                Image(systemName: showContextPrompt ? "chevron.up" : "chevron.down")
                                                    .font(.system(size: 9))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(WrenflowStyle.text.opacity(0.5))

                                        if showContextPrompt {
                                            Text(prompt)
                                                .font(WrenflowStyle.mono(10))
                                                .textSelection(.enabled)
                                                .padding(6)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(WrenflowStyle.bg)
                                                .cornerRadius(4)
                                        }
                                    }

                                    if !item.contextSummary.isEmpty {
                                        Text(item.contextSummary)
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textSecondary)
                                            .textSelection(.enabled)
                                    } else {
                                        Text("No context captured")
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textTertiary)
                                    }
                                }
                            }
                        )
                        }

                        // Transcribe Audio
                        PipelineStepView(
                            number: ppEnabled ? 3 : 2,
                            title: "Transcribe Audio",
                            durationMs: item.metrics.double("transcription.durationMs"),
                            content: {
                                VStack(alignment: .leading, spacing: 3) {
                                    if let provider = item.metrics.string("transcription.provider") {
                                        Text("Provider: \(provider)")
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textSecondary)
                                    }
                                    if !item.rawTranscript.isEmpty {
                                        Text(item.rawTranscript)
                                            .font(WrenflowStyle.mono(11))
                                            .textSelection(.enabled)
                                            .padding(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(WrenflowStyle.bg)
                                            .cornerRadius(4)
                                    } else {
                                        Text("(empty transcript)")
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textTertiary)
                                    }
                                }
                            }
                        )

                        // Post-Process (hidden when disabled)
                        if ppEnabled {
                            PipelineStepView(
                                number: 4,
                                title: "Post-Process",
                                durationMs: item.metrics.double("postProcessing.durationMs"),
                                content: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let model = item.metrics.string("postProcessing.model") {
                                            Text("Model: \(model)")
                                                .font(WrenflowStyle.caption(11))
                                                .foregroundColor(WrenflowStyle.textSecondary)
                                        }

                                        Text(item.postProcessingStatus)
                                            .font(WrenflowStyle.caption(11))
                                            .foregroundColor(WrenflowStyle.textSecondary)
                                            .textSelection(.enabled)

                                        if let prompt = item.postProcessingPrompt, !prompt.isEmpty {
                                            Button {
                                                showPostProcessingPrompt.toggle()
                                            } label: {
                                                HStack(spacing: 3) {
                                                    Text(showPostProcessingPrompt ? "Hide Prompt" : "Show Prompt")
                                                        .font(WrenflowStyle.caption(11))
                                                    Image(systemName: showPostProcessingPrompt ? "chevron.up" : "chevron.down")
                                                        .font(.system(size: 9))
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(WrenflowStyle.text.opacity(0.5))

                                            if showPostProcessingPrompt {
                                                Text(prompt)
                                                    .font(WrenflowStyle.mono(10))
                                                    .textSelection(.enabled)
                                                    .padding(6)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(WrenflowStyle.bg)
                                                    .cornerRadius(4)
                                            }
                                        }

                                        if !item.postProcessedTranscript.isEmpty {
                                            Text(item.postProcessedTranscript)
                                                .font(WrenflowStyle.mono(11))
                                                .textSelection(.enabled)
                                                .padding(6)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(WrenflowStyle.bg)
                                                .cornerRadius(4)
                                        }

                                        if let reasoning = item.postProcessingReasoning, !reasoning.isEmpty {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("LLM Reasoning")
                                                    .font(WrenflowStyle.body(11))
                                                    .foregroundColor(WrenflowStyle.textSecondary)
                                                Text(reasoning)
                                                    .font(WrenflowStyle.mono(10))
                                                    .textSelection(.enabled)
                                                    .padding(6)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(WrenflowStyle.text.opacity(0.03))
                                                    .cornerRadius(4)
                                            }
                                        }
                                    }
                                }
                            )
                        }

                        // Paste (only shown if paste happened)
                        if let pasteMs = item.metrics.double("paste.durationMs") {
                            PipelineStepView(
                                number: ppEnabled ? 5 : 3,
                                title: "Paste",
                                durationMs: pasteMs,
                                content: {
                                    Text("Pasted to active application")
                                        .font(WrenflowStyle.caption(11))
                                        .foregroundColor(WrenflowStyle.textSecondary)
                                }
                            )
                        }
                    }

                    // All Metrics dump
                    if !item.metrics.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                showAllMetrics.toggle()
                            } label: {
                                HStack(spacing: 3) {
                                    Text(showAllMetrics ? "Hide All Metrics" : "All Metrics")
                                        .font(WrenflowStyle.body(11))
                                    Image(systemName: showAllMetrics ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(WrenflowStyle.text.opacity(0.5))

                            if showAllMetrics {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(item.metrics.allKeys, id: \.self) { key in
                                        if let value = item.metrics[key] {
                                            HStack(spacing: 0) {
                                                Text(key)
                                                    .font(WrenflowStyle.mono(10))
                                                    .foregroundColor(WrenflowStyle.textTertiary)
                                                    .frame(width: 160, alignment: .leading)
                                                Text(value.displayValue)
                                                    .font(WrenflowStyle.mono(10))
                                                    .foregroundColor(WrenflowStyle.textSecondary)
                                            }
                                        }
                                    }
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(WrenflowStyle.bg)
                                .cornerRadius(4)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(WrenflowStyle.surface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isError ? WrenflowStyle.red.opacity(0.3) : WrenflowStyle.border, lineWidth: 1)
        )
    }

    private func parseVocabulary(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Duration Formatting

private func formatDurationMs(_ ms: Double) -> String {
    if ms >= 1000 {
        return String(format: "%.1fs", ms / 1000)
    } else {
        return String(format: "%.0fms", ms)
    }
}

private func formatFileSize(_ bytes: Int64) -> String {
    if bytes >= 1_000_000 {
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    } else if bytes >= 1_000 {
        return String(format: "%.1f KB", Double(bytes) / 1_000)
    } else {
        return "\(bytes) B"
    }
}

// MARK: - Pipeline Step View

struct PipelineStepView<Content: View>: View {
    let number: Int
    let title: String
    var durationMs: Double? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(WrenflowStyle.surface)
                .frame(width: 16, height: 16)
                .background(Circle().fill(WrenflowStyle.text.opacity(0.35)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(WrenflowStyle.body(11))
                        .foregroundColor(WrenflowStyle.text)
                    if let ms = durationMs {
                        Text(formatDurationMs(ms))
                            .font(WrenflowStyle.mono(10))
                            .foregroundColor(WrenflowStyle.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(WrenflowStyle.text.opacity(0.05))
                            .cornerRadius(3)
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(WrenflowStyle.bg)
        .cornerRadius(6)
    }
}

// MARK: - Audio Player

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish?()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundColor(WrenflowStyle.text)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(WrenflowStyle.text.opacity(0.08)))
            }
            .buttonStyle(.plain)

            WrenflowProgressBar(progress: progress, height: 4)
                .frame(height: 24)

            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(WrenflowStyle.mono(10))
                .foregroundColor(WrenflowStyle.textTertiary)
                .fixedSize()
        }
        .onAppear {
            loadDuration()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func loadDuration() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        if let p = try? AVAudioPlayer(contentsOf: audioURL) {
            duration = p.duration
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: audioURL)
                delegate.onFinish = {
                    self.stopPlayback()
                }
                p.delegate = delegate
                p.play()
                player = p
                isPlaying = true
                elapsed = 0
                startProgressTimer()
            } catch {}
        }
    }

    private func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let p = player, p.isPlaying {
                elapsed = p.currentTime
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layoutSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
