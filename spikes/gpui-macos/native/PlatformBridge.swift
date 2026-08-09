import AppKit
import ApplicationServices
import AVFoundation

private final class SpikeShell: NSObject {
    static let shared = SpikeShell()

    private var statusItem: NSStatusItem?
    private var overlayPanel: NSPanel?

    func install() {
        dispatchPrecondition(condition: .onQueue(.main))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🕊"
        item.button?.toolTip = "Wrenflow GPUI spike"

        let menu = NSMenu()
        menu.addItem(withTitle: "Open GPUI settings", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle native overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Request microphone permission", action: #selector(requestMicrophone), keyEquivalent: "")
        menu.addItem(withTitle: "Request accessibility permission", action: #selector(requestAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item

        setAccessoryMode()
    }

    @objc private func showSettings() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func setAccessoryMode() {
        dispatchPrecondition(condition: .onQueue(.main))
        settingsWindow?.orderOut(nil)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    @objc private func toggleOverlay() {
        if overlayPanel == nil {
            showOverlay()
        } else {
            hideOverlay()
        }
    }

    @objc private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("Wrenflow GPUI spike microphone permission: %@", granted ? "granted" : "denied")
        }
    }

    @objc private func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("Wrenflow GPUI spike accessibility permission: %@", trusted ? "granted" : "not granted")
    }

    func showOverlay() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let panel = overlayPanel {
            panel.orderFrontRegardless()
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 220, height: 42)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let label = NSTextField(labelWithString: "Native overlay bridge is alive")
        label.textColor = .white
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = frame
        panel.contentView = label

        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - frame.width / 2,
                y: screen.visibleFrame.maxY - frame.height - 8
            ))
        }
        panel.orderFrontRegardless()
        overlayPanel = panel
    }

    func hideOverlay() {
        dispatchPrecondition(condition: .onQueue(.main))
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private var settingsWindow: NSWindow? {
        NSApplication.shared.windows.first { window in
            !(window is NSPanel) && window.title == "Wrenflow GPUI Spike"
        }
    }
}

@_cdecl("wrenflow_spike_install_shell")
public func wrenflowSpikeInstallShell() {
    SpikeShell.shared.install()
}

@_cdecl("wrenflow_spike_set_accessory_mode")
public func wrenflowSpikeSetAccessoryMode() {
    SpikeShell.shared.setAccessoryMode()
}

@_cdecl("wrenflow_spike_show_overlay")
public func wrenflowSpikeShowOverlay() {
    SpikeShell.shared.showOverlay()
}

@_cdecl("wrenflow_spike_hide_overlay")
public func wrenflowSpikeHideOverlay() {
    SpikeShell.shared.hideOverlay()
}
