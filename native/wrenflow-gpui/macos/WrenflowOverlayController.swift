import AppKit
import SwiftUI

enum WrenflowOverlayPhase: String {
    case initializing
    case recording
    case transcribing
}

private final class WrenflowOverlayState: ObservableObject {
    @Published var phase: WrenflowOverlayPhase = .initializing
    @Published var audioLevel: Float = 0
}

/// Native screenSaver-level panels stay independent of the GPUI settings
/// window. The runtime boundary is a typed callback owned by the AppKit shell.
final class WrenflowOverlayController {
    private var recordingPanel: NSPanel?
    private var transcribingPanel: NSPanel?
    private var errorPanel: NSPanel?
    private var errorDismissTimer: Timer?
    private var lastAnnouncedPhase: WrenflowOverlayPhase?
    private let state = WrenflowOverlayState()
    private let onAction: (String) -> Void

    init(onAction: @escaping (String) -> Void) {
        self.onAction = onAction
    }

    func show(phase: WrenflowOverlayPhase, audioLevel: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        state.phase = phase
        state.audioLevel = phase == .recording ? audioLevel : 0
        if lastAnnouncedPhase != phase {
            lastAnnouncedPhase = phase
            let announcement = switch phase {
            case .initializing: "Preparing dictation"
            case .recording: "Recording"
            case .transcribing: "Transcribing"
            }
            announce(announcement, priority: .medium)
        }
        switch phase {
        case .initializing, .recording:
            showRecordingPanel()
            hideTranscribingPanel()
        case .transcribing:
            hideRecordingPanel()
            showTranscribingPanel()
        }
    }

    func updateAudioLevel(_ level: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        state.audioLevel = min(max(level, 0), 1)
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        hideRecordingPanel()
        hideTranscribingPanel()
    }

    func showError(message: String, actionLabel: String?, actionID: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        errorPanel?.orderOut(nil)
        errorPanel = nil
        errorDismissTimer?.invalidate()

        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = actionLabel == nil ? 72 : 88
        let panel = Self.makePanel(width: panelWidth, height: panelHeight)
        panel.ignoresMouseEvents = false
        let view = WrenflowErrorToastView(
            message: message,
            actionLabel: actionLabel,
            onAction: { [weak self] in
                if let actionID {
                    self?.onAction(actionID)
                }
                self?.dismissError()
            }
        )
        let hosting = NSHostingView(rootView:
            view
                .frame(width: panelWidth, height: panelHeight)
                .background(Color(red: 0.95, green: 0.3, blue: 0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView = hosting
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - panelWidth / 2,
                y: screen.visibleFrame.maxY - panelHeight - 8
            ))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if shouldReduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }
        errorPanel = panel
        announce(message, priority: .high)
        errorDismissTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismissError() }
        }
    }

    func shutdown() {
        dispatchPrecondition(condition: .onQueue(.main))
        errorDismissTimer?.invalidate()
        recordingPanel?.orderOut(nil)
        transcribingPanel?.orderOut(nil)
        errorPanel?.orderOut(nil)
        recordingPanel = nil
        transcribingPanel = nil
        errorPanel = nil
        lastAnnouncedPhase = nil
    }

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func announce(_ message: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }

    private static func makePanel(width: CGFloat, height: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func contentView<V: View>(
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat,
        rootView: V
    ) -> NSView {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius
        )
        let content = rootView
            .frame(width: width, height: height)
            .background(Color(white: 0.96))
            .clipShape(shape)
            .overlay(shape.stroke(Color.black.opacity(0.08), lineWidth: 0.5))
            .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    private var screenHasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    private var notchWidth: CGFloat {
        guard screenHasNotch,
              let screen = NSScreen.main,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return 0 }
        return screen.frame.width - leftArea.width - rightArea.width
    }

    private var notchOverlap: CGFloat {
        guard let screen = NSScreen.main else { return 0 }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    private func showRecordingPanel() {
        let hasNotch = screenHasNotch
        let width: CGFloat = hasNotch ? max(notchWidth, 120) : 120
        let overlap = hasNotch ? notchOverlap : 0
        let height: CGFloat = 32 + overlap
        guard let screen = NSScreen.main else { return }
        let visibleFrame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )

        if let panel = recordingPanel {
            panel.setFrame(visibleFrame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = Self.makePanel(width: width, height: height)
        panel.contentView = Self.contentView(
            width: width,
            height: height,
            cornerRadius: hasNotch ? 18 : 12,
            rootView: WrenflowRecordingOverlayView(state: state).padding(.top, overlap)
        )
        panel.setFrame(
            NSRect(x: visibleFrame.minX, y: screen.frame.maxY, width: width, height: height),
            display: true
        )
        panel.orderFrontRegardless()
        if shouldReduceMotion {
            panel.setFrame(visibleFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
                panel.animator().setFrame(visibleFrame, display: true)
            }
        }
        recordingPanel = panel
    }

    private func hideRecordingPanel() {
        guard let panel = recordingPanel, let screen = NSScreen.main else { return }
        let frame = panel.frame
        recordingPanel = nil
        if shouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            panel.animator().setFrameOrigin(NSPoint(x: frame.minX, y: screen.frame.maxY))
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func showTranscribingPanel() {
        guard transcribingPanel == nil, let screen = NSScreen.main else { return }
        let hasNotch = screenHasNotch
        let overlap = hasNotch ? notchOverlap : 0
        let width: CGFloat = 44
        let height: CGFloat = 22 + overlap
        let panel = Self.makePanel(width: width, height: height)
        panel.contentView = Self.contentView(
            width: width,
            height: height,
            cornerRadius: hasNotch ? 14 : 11,
            rootView: WrenflowOverlayDotsView().padding(.top, overlap)
        )
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height
        ))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if shouldReduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }
        transcribingPanel = panel
    }

    private func hideTranscribingPanel() {
        guard let panel = transcribingPanel else { return }
        transcribingPanel = nil
        if shouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func dismissError() {
        guard let panel = errorPanel else { return }
        errorPanel = nil
        if shouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private struct WrenflowRecordingOverlayView: View {
    @ObservedObject var state: WrenflowOverlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state.phase == .initializing {
                WrenflowOverlayDotsView()
            } else {
                WrenflowOverlayWaveformView(audioLevel: state.audioLevel)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: state.phase == .initializing
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.phase == .recording ? "Recording" : "Preparing dictation")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WrenflowOverlayDotsView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(white: 0.15).opacity(activeDot == index ? 0.7 : 0.15))
                    .frame(width: 4.5, height: 4.5)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
        .onAppear {
            guard !reduceMotion else { return }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async { activeDot = (activeDot + 1) % 3 }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

private struct WrenflowOverlayWaveformView: View {
    let audioLevel: Float
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.multipliers.count, id: \.self) { index in
                let amplitude = min(CGFloat(audioLevel) * Self.multipliers[index], 1)
                Capsule()
                    .fill(Color(white: 0.15).opacity(0.6))
                    .frame(width: 3, height: 2 + 18 * amplitude)
                    .animation(
                        reduceMotion ? nil : .interpolatingSpring(stiffness: 600, damping: 28),
                        value: audioLevel
                    )
            }
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityValue("Audio level \(Int(audioLevel * 100)) percent")
    }
}

private struct WrenflowErrorToastView: View {
    let message: String
    let actionLabel: String?
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text("▲").font(.system(size: 14, weight: .bold))
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            if let actionLabel {
                Button(actionLabel, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.3))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
