import AppKit
import Darwin
import Foundation

func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else {
        fputs("paste-target: could not encode marker\n", stderr)
        exit(70)
    }
    print(line)
    fflush(stdout)
}

if CommandLine.arguments.contains("--self-test") {
    emit([
        "event": "self_test",
        "privacy": "character_count_only",
        "timestamp_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
    ])
    exit(0)
}

final class ProbeDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var window: NSWindow?
    private var sequence = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wrenflow performance paste target"
        let textView = NSTextView(frame: frame)
        textView.isEditable = true
        textView.isSelectable = true
        textView.delegate = self
        textView.string = ""
        window.contentView = textView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
        self.window = window
        emit([
            "event": "paste_target_ready",
            "privacy": "character_count_only",
            "timestamp_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ])
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        sequence += 1
        emit([
            "event": "text_changed",
            "timestamp_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "uptime_ns": clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            "sequence": sequence,
            "character_count": textView.string.utf16.count,
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
let delegate = ProbeDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
