import SwiftUI
import Combine
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var modelDownloadWindow: NSWindow?
    private var modelStateCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )

        setupDistributedNotifications()

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            Task { @MainActor in
                UpdateManager.shared.startPeriodicChecks()
            }

            // No permission alerts on launch — permissions are checked lazily:
            // - Mic: on first hotkey press (ensureMicrophoneAccess)
            // - Accessibility: polled silently (startAccessibilityPolling), shown in menu bar
            // - Screen Recording: checked when post-processing needs a screenshot

            if appState.selectedTranscriptionProvider == .local
                && !appState.localTranscriptionService.state.isReady {
                showModelDownloadWindow()
            }
        }

    }

    @objc func handleShowSetup() {
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        showSetupWindow()
    }

    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wrenflow"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
        }
    }

    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupAccordionView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Wrenflow"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
        appState.warmUpAfterSetup()
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        Task { @MainActor in
            UpdateManager.shared.startPeriodicChecks()
        }

        // Don't show alert here — menu bar already indicates missing permissions.
        // User will see it when they try to record.
    }

    private func setupDistributedNotifications() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleDistributedStartRecording),
            name: .init("me.gulya.wrenflow.start-recording"),
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDistributedStopRecording),
            name: .init("me.gulya.wrenflow.stop-recording"),
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDistributedToggleRecording),
            name: .init("me.gulya.wrenflow.toggle-recording"),
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDistributedStatusRequest),
            name: .init("me.gulya.wrenflow.status-request"),
            object: nil
        )
    }

    @objc private func handleDistributedStartRecording() {
        DispatchQueue.main.async {
            self.appState.startRecordingFromCLI()
            self.sendAck("start")
        }
    }

    @objc private func handleDistributedStopRecording() {
        DispatchQueue.main.async {
            self.appState.stopRecordingFromCLI()
            self.sendAck("stop")
        }
    }

    @objc private func handleDistributedToggleRecording() {
        DispatchQueue.main.async {
            self.appState.toggleRecording()
            self.sendAck("toggle")
        }
    }

    private func sendAck(_ command: String) {
        let state = appState.isRecording ? "recording" : "idle"
        DistributedNotificationCenter.default().postNotificationName(
            .init("me.gulya.wrenflow.ack"),
            object: "\(command):\(state)",
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @objc private func handleDistributedStatusRequest() {
        let state = appState.isRecording ? "recording" : "idle"
        DistributedNotificationCenter.default().postNotificationName(
            .init("me.gulya.wrenflow.status-response"),
            object: state,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func showModelDownloadWindow() {
        guard modelDownloadWindow == nil else { return }

        let view = ModelDownloadView(
            localTranscriptionService: appState.localTranscriptionService,
            onDismiss: { [weak self] in
                self?.modelDownloadWindow?.close()
                self?.modelDownloadWindow = nil
            }
        )

        let panel = NSPanel.wrenflowPanel(content: view)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        modelDownloadWindow = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.modelDownloadWindow = nil
        }

        // Auto-close when model becomes ready
        modelStateCancellable = appState.localTranscriptionService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state.isReady {
                    self?.modelDownloadWindow?.close()
                    self?.modelDownloadWindow = nil
                    self?.modelStateCancellable = nil
                }
            }
    }
}
