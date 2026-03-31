import Cocoa
import FlutterMacOS
import SwiftUI

// MARK: - Overlay State

class OverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .initializing
    @Published var audioLevel: Float = 0.0
}

enum OverlayPhase {
    case initializing
    case recording
    case transcribing
}

// MARK: - Panel Factory

private func makeOverlayPanel(width: CGFloat, height: CGFloat) -> NSPanel {
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
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

private func makeOverlayContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    rootView: V
) -> NSView {
    let content = rootView
        .frame(width: width, height: height)
        .background(Color(white: 0.96))
        .environment(\.colorScheme, .light)

    let shaped: AnyView
    if #available(macOS 13.0, *) {
        shaped = AnyView(
            content
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))
                .overlay(
                    UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
                        .stroke(Color(white: 0.0).opacity(0.08), lineWidth: 0.5)
                )
        )
    } else {
        shaped = AnyView(
            content
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(white: 0.0).opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    let hosting = NSHostingView(rootView: shaped)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

// MARK: - OverlayHandler (MethodChannel bridge)

class OverlayHandler {
    private let channel: FlutterMethodChannel
    private var overlayPanel: NSPanel?
    private var transcribingPanel: NSPanel?
    private let overlayState = OverlayState()

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "dev.gulya.wrenflow/overlay",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "show":
            guard let args = call.arguments as? [String: Any],
                  let stateStr = args["state"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing state", details: nil))
                return
            }
            let audioLevel = args["audioLevel"] as? Double ?? 0.0
            show(state: stateStr, audioLevel: Float(audioLevel))
            result(nil)

        case "updateAudioLevel":
            guard let args = call.arguments as? [String: Any],
                  let level = args["level"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing level", details: nil))
                return
            }
            overlayState.audioLevel = Float(level)
            result(nil)

        case "hide":
            hide()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Screen helpers

    private var screenHasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    private var notchWidth: CGFloat {
        guard let screen = NSScreen.main, screenHasNotch else { return 0 }
        if #available(macOS 12.0, *) {
            guard let leftArea = screen.auxiliaryTopLeftArea,
                  let rightArea = screen.auxiliaryTopRightArea else { return 0 }
            return screen.frame.width - leftArea.width - rightArea.width
        }
        return 0
    }

    private var notchOverlap: CGFloat {
        guard let screen = NSScreen.main else { return 0 }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    private func panelX(_ screen: NSScreen, width: CGFloat) -> CGFloat {
        screen.frame.midX - width / 2
    }

    // MARK: - Show / Hide

    private func show(state: String, audioLevel: Float) {
        DispatchQueue.main.async { [self] in
            switch state {
            case "initializing":
                overlayState.phase = .initializing
                overlayState.audioLevel = 0
                showRecordingPanel()
                hideTranscribingPanel()
            case "recording":
                overlayState.phase = .recording
                overlayState.audioLevel = audioLevel
                showRecordingPanel()
                hideTranscribingPanel()
            case "transcribing":
                overlayState.phase = .transcribing
                hideRecordingPanel()
                showTranscribingPanel()
            default:
                hide()
            }
        }
    }

    private func hide() {
        DispatchQueue.main.async { [self] in
            hideRecordingPanel()
            hideTranscribingPanel()
        }
    }

    // MARK: - Recording panel (initializing + recording)

    private func showRecordingPanel() {
        let hasNotch = screenHasNotch
        let panelWidth: CGFloat = hasNotch ? max(notchWidth, 120) : 120
        let contentHeight: CGFloat = 32
        let overlap = hasNotch ? notchOverlap : 0
        let panelHeight = contentHeight + overlap

        if let panel = overlayPanel {
            guard let screen = NSScreen.main else { return }
            let x = panelX(screen, width: panelWidth)
            let y = screen.frame.maxY - panelHeight
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight)

        let view = RecordingOverlaySwiftUIView(state: overlayState)
        panel.contentView = makeOverlayContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: hasNotch ? 18 : 12,
            rootView: view.padding(.top, overlap)
        )

        guard let screen = NSScreen.main else { return }
        let x = panelX(screen, width: panelWidth)
        let hiddenY = screen.frame.maxY
        let visibleY = screen.frame.maxY - panelHeight

        panel.setFrame(NSRect(x: x, y: hiddenY, width: panelWidth, height: panelHeight), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(
                NSRect(x: x, y: visibleY, width: panelWidth, height: panelHeight),
                display: true
            )
        }

        self.overlayPanel = panel
    }

    private func hideRecordingPanel() {
        guard let panel = overlayPanel, let screen = NSScreen.main else { return }

        let hiddenY = screen.frame.maxY
        let frame = panel.frame

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().setFrame(
                NSRect(x: frame.origin.x, y: hiddenY, width: frame.width, height: frame.height),
                display: true
            )
        }, completionHandler: {
            panel.orderOut(nil)
            self.overlayPanel = nil
        })
    }

    // MARK: - Transcribing panel (small dots)

    private func showTranscribingPanel() {
        if transcribingPanel != nil { return }

        let hasNotch = screenHasNotch
        let contentHeight: CGFloat = 22
        let overlap = hasNotch ? notchOverlap : 0
        let panelWidth: CGFloat = 44
        let panelHeight = contentHeight + overlap

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight)

        let view = OverlayDotsView()
        panel.contentView = makeOverlayContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: hasNotch ? 14 : 11,
            rootView: view.padding(.top, overlap)
        )

        if let screen = NSScreen.main {
            let x = panelX(screen, width: panelWidth)
            let y = screen.frame.maxY - panelHeight
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }

        self.transcribingPanel = panel
    }

    private func hideTranscribingPanel() {
        guard let panel = transcribingPanel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            self.transcribingPanel = nil
        })
    }
}

// MARK: - SwiftUI Views

struct RecordingOverlaySwiftUIView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        Group {
            if state.phase == .initializing {
                OverlayDotsView()
                    .transition(.opacity)
            } else {
                OverlayWaveformView(audioLevel: state.audioLevel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.phase == .initializing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OverlayDotsView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(white: 0.15).opacity(activeDot == index ? 0.7 : 0.15))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .onAppear {
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

struct OverlayWaveformView: View {
    let audioLevel: Float

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                OverlayWaveformBar(amplitude: barAmplitude(for: index))
                    .animation(
                        .interpolatingSpring(stiffness: 600, damping: 28),
                        value: audioLevel
                    )
            }
        }
        .frame(height: 20)
    }

    private func barAmplitude(for index: Int) -> CGFloat {
        let level = CGFloat(audioLevel)
        return min(level * Self.multipliers[index], 1.0)
    }
}

struct OverlayWaveformBar: View {
    let amplitude: CGFloat

    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 20

    var body: some View {
        Capsule()
            .fill(Color(white: 0.15).opacity(0.6))
            .frame(width: 3, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}
