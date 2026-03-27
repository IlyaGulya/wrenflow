import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var permissionHandler: PermissionHandler?
  private var launchAtLoginHandler: LaunchAtLoginHandler?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    let messenger = controller.engine.binaryMessenger
    permissionHandler = PermissionHandler(messenger: messenger)
    launchAtLoginHandler = LaunchAtLoginHandler(messenger: messenger)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Menu bar app — keep running when the window is closed.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
