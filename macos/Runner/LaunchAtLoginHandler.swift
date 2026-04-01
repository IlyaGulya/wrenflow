import Cocoa
import FlutterMacOS
import ServiceManagement

class LaunchAtLoginHandler {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "dev.gulya.wrenflow/launch_at_login", binaryMessenger: messenger)
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isEnabled":
            if #available(macOS 13.0, *) {
                result(SMAppService.mainApp.status == .enabled)
            } else {
                result(false)
            }

        case "setEnabled":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'enabled' argument", details: nil))
                return
            }
            if #available(macOS 13.0, *) {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    result(nil)
                } catch {
                    result(FlutterError(code: "SM_ERROR", message: error.localizedDescription, details: nil))
                }
            } else {
                result(FlutterError(code: "UNSUPPORTED", message: "Requires macOS 13.0+", details: nil))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
