import Cocoa
import FlutterMacOS
import AVFoundation
import ApplicationServices

class PermissionHandler {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "dev.gulya.wrenflow/permissions",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkMicrophonePermission":
            result(checkMicrophonePermission())

        case "requestMicrophonePermission":
            requestMicrophonePermission(result: result)

        case "checkAccessibilityPermission":
            result(checkAccessibilityPermission())

        case "requestAccessibilityPermission":
            result(requestAccessibilityPermission())

        case "openAccessibilitySettings":
            openAccessibilitySettings()
            result(nil)

        case "openMicrophoneSettings":
            openMicrophoneSettings()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Microphone

    private func checkMicrophonePermission() -> String {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let statusString: String
        switch status {
        case .authorized:
            statusString = "granted"
        case .denied, .restricted:
            statusString = "denied"
        case .notDetermined:
            statusString = "notDetermined"
        @unknown default:
            statusString = "notDetermined"
        }
        NSLog("[PermissionHandler] checkMicrophone: AVAuthorizationStatus=\(status.rawValue) → \(statusString)")
        return statusString
    }

    private func requestMicrophonePermission(result: @escaping FlutterResult) {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("[PermissionHandler] requestMicrophone: currentStatus=\(currentStatus.rawValue)")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("[PermissionHandler] requestMicrophone callback: granted=\(granted)")
            DispatchQueue.main.async {
                result(granted)
            }
        }
    }

    // MARK: - Accessibility

    private func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    private func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Open Settings

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
