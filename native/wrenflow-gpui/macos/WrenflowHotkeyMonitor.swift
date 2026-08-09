import CoreGraphics
import Foundation

/// Listen-only CGEventTap used by the GPUI shell while the legacy raw-input
/// runtime feature is disabled. Events are emitted through the typed shell ABI;
/// recording and transcription remain owned by the Rust runtime.
final class WrenflowHotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targetKeyCode: CGKeyCode = 63
    private var pressedAt: TimeInterval?
    private let onPressed: () -> Void
    private let onReleased: (TimeInterval) -> Void

    init(onPressed: @escaping () -> Void, onReleased: @escaping (TimeInterval) -> Void) {
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    var isRunning: Bool { eventTap != nil }

    func setTargetKeyCode(_ keyCode: UInt16) {
        dispatchPrecondition(condition: .onQueue(.main))
        targetKeyCode = CGKeyCode(keyCode)
        pressedAt = nil
    }

    @discardableResult
    func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }

        let mask = eventMask(.keyDown) | eventMask(.keyUp) | eventMask(.flagsChanged)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: wrenflowHotkeyEventCallback,
            userInfo: context
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        pressedAt = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return }
        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            setPressed(true)
        case .keyUp:
            setPressed(false)
        case .flagsChanged:
            guard let flag = Self.modifierFlag(for: keyCode) else { return }
            setPressed(event.flags.contains(flag))
        default:
            break
        }
    }

    private func setPressed(_ pressed: Bool) {
        if pressed {
            guard pressedAt == nil else { return }
            pressedAt = ProcessInfo.processInfo.systemUptime
            onPressed()
        } else {
            guard let started = pressedAt else { return }
            pressedAt = nil
            onReleased(max(0, ProcessInfo.processInfo.systemUptime - started))
        }
    }

    private static func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }
}

private func eventMask(_ type: CGEventType) -> CGEventMask {
    CGEventMask(1) << type.rawValue
}

private func wrenflowHotkeyEventCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<WrenflowHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
