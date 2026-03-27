import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var permissionHandler: PermissionHandler?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    permissionHandler = PermissionHandler(messenger: controller.engine.binaryMessenger)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
