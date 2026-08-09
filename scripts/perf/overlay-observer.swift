import CoreGraphics
import Darwin
import Foundation

func fail(_ message: String, code: Int32 = 64) -> Never {
    fputs("overlay-observer: \(message)\n", stderr)
    exit(code)
}

func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else {
        fail("could not encode marker", code: 70)
    }
    print(line)
    fflush(stdout)
}

guard CommandLine.arguments.count == 3,
      let requestedPID = Int32(CommandLine.arguments[1]),
      let durationSeconds = Double(CommandLine.arguments[2]),
      requestedPID > 1,
      durationSeconds > 0 else {
    fail("usage: overlay-observer <exact-wrenflow-pid> <duration-seconds>")
}

func overlays() -> [CGWindowID: (layer: Int, width: Double, height: Double)] {
    guard let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return [:]
    }
    var found: [CGWindowID: (layer: Int, width: Double, height: Double)] = [:]
    for entry in raw {
        guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
              owner.int32Value == requestedPID,
              let number = entry[kCGWindowNumber as String] as? NSNumber,
              let layerNumber = entry[kCGWindowLayer as String] as? NSNumber,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let widthNumber = bounds["Width"] as? NSNumber,
              let heightNumber = bounds["Height"] as? NSNumber else {
            continue
        }
        let layer = layerNumber.intValue
        let width = widthNumber.doubleValue
        let height = heightNumber.doubleValue
        // Product overlays are screenSaver-level NSPanels. Layer-zero GPUI
        // windows and any status-item implementation detail are not markers.
        guard layer > 0, width >= 20, width <= 600, height >= 15, height <= 120 else {
            continue
        }
        found[CGWindowID(number.uint32Value)] = (layer, width, height)
    }
    return found
}

emit([
    "event": "observer_ready",
    "pid": requestedPID,
    "timestamp_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
])

let deadline = ProcessInfo.processInfo.systemUptime + durationSeconds
var previous = overlays()
while ProcessInfo.processInfo.systemUptime < deadline {
    let current = overlays()
    for (windowID, window) in current where previous[windowID] == nil {
        let kind: String
        if window.width >= 400 {
            kind = "error"
        } else if window.width >= 80 {
            kind = "recording"
        } else {
            kind = "transcribing"
        }
        emit([
            "event": "overlay_shown",
            "pid": requestedPID,
            "timestamp_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "uptime_ns": clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            "window_id": windowID,
            "kind": kind,
            "layer": window.layer,
            "width": window.width,
            "height": window.height,
        ])
    }
    previous = current
    usleep(2_000)
}
