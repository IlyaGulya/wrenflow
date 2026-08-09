import Foundation

struct Limits: Decodable {
    let changedPixelPercent: Double
    let meanAbsoluteError: Double
}

struct Thresholds: Decodable {
    let revision: Int
    let screens: [String: Limits]
}

struct Metrics: Decodable {
    let width: Int
    let height: Int
    let cropTop: Int
    let changedPixelPercent: Double
    let meanAbsoluteError: Double
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("visual-parity-verify: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fail("usage: verify-visual-parity.swift THRESHOLDS.json EVIDENCE_DIR")
}

let decoder = JSONDecoder()
let thresholdsURL = URL(fileURLWithPath: arguments[0])
let evidenceURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard let thresholdData = try? Data(contentsOf: thresholdsURL),
      let thresholds = try? decoder.decode(Thresholds.self, from: thresholdData),
      thresholds.revision == 1 else {
    fail("threshold contract is missing, malformed, or unsupported")
}

for (screen, limits) in thresholds.screens.sorted(by: { $0.key < $1.key }) {
    for suffix in [
        "flutter-\(screen).png",
        "gpui-\(screen).png",
        "\(screen)-overlay.png",
        "\(screen)-diff-4x.png",
    ] {
        let url = evidenceURL.appendingPathComponent(suffix)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("missing \(url.path)")
        }
    }
    let metricsURL = evidenceURL.appendingPathComponent("\(screen)-metrics.json")
    guard let data = try? Data(contentsOf: metricsURL),
          let metrics = try? decoder.decode(Metrics.self, from: data) else {
        fail("missing or malformed \(metricsURL.path)")
    }
    guard metrics.width == 720, metrics.height == 520, metrics.cropTop == 31 else {
        fail("\(screen) must be a comparable 720x520 capture with the 31px titlebar crop")
    }
    guard metrics.changedPixelPercent <= limits.changedPixelPercent else {
        fail("\(screen) changed pixels \(metrics.changedPixelPercent) exceed \(limits.changedPixelPercent)")
    }
    guard metrics.meanAbsoluteError <= limits.meanAbsoluteError else {
        fail("\(screen) MAE \(metrics.meanAbsoluteError) exceeds \(limits.meanAbsoluteError)")
    }
    print(
        "visual_parity=ok screen=\(screen) changed=\(metrics.changedPixelPercent) mae=\(metrics.meanAbsoluteError)"
    )
}
