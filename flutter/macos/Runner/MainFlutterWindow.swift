import Cocoa
import FlutterMacOS
import macos_window_utils
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let windowFrame = self.frame
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)

    // Start invisible — WindowSynchronizer reveals after first frame renders.
    self.alphaValue = 0
    self.backgroundColor = NSColor(red: 252/255, green: 252/255, blue: 252/255, alpha: 1.0)

    // Disable state restoration — we control size/position from Dart.
    self.isRestorable = false

    // Prevent black flash — clear Flutter's default black background.
    macOSWindowUtilsViewController.flutterViewController.backgroundColor = .clear

    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
    }

    RegisterGeneratedPlugins(registry: macOSWindowUtilsViewController.flutterViewController)

    super.awakeFromNib()
  }
}
