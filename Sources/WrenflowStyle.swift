import SwiftUI

/// Wrenflow design system — shared colors, fonts, and reusable components.
/// Light, minimal, warm off-white background with dark text.
enum WrenflowStyle {

    // MARK: - Colors

    /// Primary background (off-white, warm)
    static let bg = Color(white: 0.96)
    /// Card / elevated surface
    static let surface = Color(white: 0.99)
    /// Primary text
    static let text = Color(white: 0.15)
    /// Secondary text
    static let textSecondary = Color(white: 0.45)
    /// Tertiary / hint text
    static let textTertiary = Color(white: 0.6)
    /// Subtle border / divider
    static let border = Color(white: 0.15).opacity(0.08)
    /// Progress bar track
    static let trackBg = Color(white: 0.15).opacity(0.08)
    /// Progress bar fill
    static let trackFill = Color(white: 0.15).opacity(0.45)
    /// Success green
    static let green = Color(red: 0.2, green: 0.7, blue: 0.4)
    /// Error red
    static let red = Color(red: 0.85, green: 0.25, blue: 0.2)

    // MARK: - Typography

    static func title(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .medium)
    }

    static func body(_ size: CGFloat = 14) -> Font {
        .system(size: size)
    }

    static func mono(_ size: CGFloat = 14) -> Font {
        .system(size: size, design: .monospaced)
    }

    static func caption(_ size: CGFloat = 12) -> Font {
        .system(size: size)
    }

    // MARK: - Panel modifier (floating borderless window style)

    /// Apply to a SwiftUI view before hosting in a borderless NSPanel.
    struct PanelStyle: ViewModifier {
        var width: CGFloat = 380

        func body(content: Content) -> some View {
            content
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .background(WrenflowStyle.bg)
                .environment(\.colorScheme, .light)
        }
    }
}

extension View {
    /// Apply Wrenflow floating panel style (light bg, fixed width, auto height).
    func wrenflowPanel(width: CGFloat = 380) -> some View {
        modifier(WrenflowStyle.PanelStyle(width: width))
    }
}

// MARK: - Reusable progress bar

struct WrenflowProgressBar: View {
    var progress: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(WrenflowStyle.trackBg)
                    .frame(height: height)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(WrenflowStyle.trackFill)
                    .frame(width: max(height, geo.size.width * CGFloat(progress)), height: height)
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: height)
    }
}

// MARK: - NSPanel helper

extension NSPanel {
    /// Create a Wrenflow-style floating borderless panel with rounded corners.
    static func wrenflowPanel<Content: View>(content: Content) -> NSPanel {
        let hostingView = NSHostingView(rootView: content)
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        panel.center()
        return panel
    }
}
