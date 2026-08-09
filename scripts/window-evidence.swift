import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2,
      let requestedPID = Int32(CommandLine.arguments[1]),
      let windowInfo = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements],
          kCGNullWindowID
      ) as? [[String: Any]] else {
    fputs("Usage: window-evidence.swift <pid>\n", stderr)
    exit(64)
}

let windows = windowInfo.filter { entry in
    guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
          let layer = entry[kCGWindowLayer as String] as? Int,
          let bounds = entry[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double else {
        return false
    }
    return ownerPID == requestedPID && layer == 0 && width > 1 && height > 1
}

print("visibleLayerZeroWindows=\(windows.count)")
for window in windows {
    let name = window[kCGWindowName as String] as? String ?? "<untitled>"
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("window=\(name) bounds=\(bounds)")
}

if windows.isEmpty {
    exit(66)
}
