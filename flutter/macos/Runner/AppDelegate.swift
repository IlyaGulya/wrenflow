import Cocoa
import FlutterMacOS
import macos_window_utils

@main
class AppDelegate: FlutterAppDelegate {
  private var permissionHandler: PermissionHandler?
  private var launchAtLoginHandler: LaunchAtLoginHandler?
  private var overlayHandler: OverlayHandler?
  private var appPolicyChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let utilsVC = mainFlutterWindow?.contentViewController as! MacOSWindowUtilsViewController
    let controller = utilsVC.flutterViewController
    let messenger = controller.engine.binaryMessenger
    permissionHandler = PermissionHandler(messenger: messenger)
    launchAtLoginHandler = LaunchAtLoginHandler(messenger: messenger)
    overlayHandler = OverlayHandler(messenger: messenger)

    // Channel for Dart to toggle dock icon visibility.
    appPolicyChannel = FlutterMethodChannel(
      name: "dev.gulya.wrenflow/app_policy",
      binaryMessenger: messenger
    )
    appPolicyChannel?.setMethodCallHandler { call, result in
      switch call.method {
      case "setShowInDock":
        guard let args = call.arguments as? [String: Any],
              let show = args["show"] as? Bool else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing show", details: nil))
          return
        }
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        NSApplication.shared.setActivationPolicy(policy)
        if show {
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Menu bar app — keep running when the window is closed.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
