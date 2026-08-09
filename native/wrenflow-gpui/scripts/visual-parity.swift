import AppKit
import Foundation

struct Raster {
    let width: Int
    let height: Int
    var rgba: [UInt8]
}

struct Metrics: Encodable {
    let reference: String
    let candidate: String
    let width: Int
    let height: Int
    let cropTop: Int
    let meanAbsoluteError: Double
    let rootMeanSquareError: Double
    let percentile95AbsoluteError: Double
    let changedPixelPercent: Double
    let changedPixelThreshold: Double
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("visual-parity: \(message)\n".utf8))
    exit(2)
}

func load(_ path: String) -> Raster {
    guard let source = NSImage(contentsOfFile: path),
          let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("cannot decode PNG at \(path)")
    }
    let pixelWidth: Int = image.width
    let pixelHeight: Int = image.height
    var rgba = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: &rgba,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fail("cannot allocate RGBA context")
    }
    context.interpolationQuality = CGInterpolationQuality.none
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    return Raster(width: pixelWidth, height: pixelHeight, rgba: rgba)
}

func write(_ raster: Raster, to path: String) {
    let data = Data(raster.rgba)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
              width: raster.width,
              height: raster.height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: raster.width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue:
                  CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              ),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ) else {
        fail("cannot encode RGBA image")
    }
    let representation = NSBitmapImageRep(cgImage: image)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        fail("cannot encode PNG")
    }
    do {
        try FileManager.default.createDirectory(
            at: Foundation.URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: Foundation.URL(fileURLWithPath: path), options: .atomic)
    } catch {
        fail("cannot write \(path): \(error.localizedDescription)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 || arguments.count == 5 else {
    fail("usage: visual-parity.swift REFERENCE.png CANDIDATE.png OUTPUT_PREFIX [--crop-top PIXELS]")
}
let referencePath = arguments[0]
let candidatePath = arguments[1]
let outputPrefix = arguments[2]
var cropTop = 31
if arguments.count == 5 {
    guard arguments[3] == "--crop-top", let parsed = Int(arguments[4]), parsed >= 0 else {
        fail("--crop-top must be a non-negative integer")
    }
    cropTop = parsed
}

let reference = load(referencePath)
let candidate = load(candidatePath)
guard reference.width == candidate.width, reference.height == candidate.height else {
    fail("dimension mismatch: reference \(reference.width)x\(reference.height), candidate \(candidate.width)x\(candidate.height)")
}
guard cropTop < reference.height else { fail("crop exceeds image height") }

var overlay = reference
var amplifiedDiff = reference
var channelErrors = [Double]()
channelErrors.reserveCapacity(reference.width * (reference.height - cropTop) * 3)
var changedPixels = 0
let changedThreshold = 0.05

for y in 0..<reference.height {
    for x in 0..<reference.width {
        let offset = (y * reference.width + x) * 4
        var pixelChanged = false
        for channel in 0..<3 {
            let referenceValue = Int(reference.rgba[offset + channel])
            let candidateValue = Int(candidate.rgba[offset + channel])
            overlay.rgba[offset + channel] = UInt8((referenceValue + candidateValue) / 2)
            let delta = abs(referenceValue - candidateValue)
            amplifiedDiff.rgba[offset + channel] = UInt8(min(255, delta * 4))
            if y >= cropTop {
                let normalized = Double(delta) / 255.0
                channelErrors.append(normalized)
                pixelChanged = pixelChanged || normalized > changedThreshold
            }
        }
        overlay.rgba[offset + 3] = 255
        amplifiedDiff.rgba[offset + 3] = 255
        if y >= cropTop, pixelChanged { changedPixels += 1 }
    }
}

guard !channelErrors.isEmpty else { fail("no compared pixels") }
let absoluteSum = channelErrors.reduce(0, +)
let squaredSum = channelErrors.reduce(0) { $0 + $1 * $1 }
let sortedErrors = channelErrors.sorted()
let percentileIndex = min(sortedErrors.count - 1, Int(Double(sortedErrors.count - 1) * 0.95))
let comparedPixels = reference.width * (reference.height - cropTop)
let metrics = Metrics(
    reference: referencePath,
    candidate: candidatePath,
    width: reference.width,
    height: reference.height,
    cropTop: cropTop,
    meanAbsoluteError: absoluteSum / Double(channelErrors.count),
    rootMeanSquareError: sqrt(squaredSum / Double(channelErrors.count)),
    percentile95AbsoluteError: sortedErrors[percentileIndex],
    changedPixelPercent: Double(changedPixels) * 100.0 / Double(comparedPixels),
    changedPixelThreshold: changedThreshold
)

write(overlay, to: "\(outputPrefix)-overlay.png")
write(amplifiedDiff, to: "\(outputPrefix)-diff-4x.png")
do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let json = try encoder.encode(metrics)
    try json.write(to: Foundation.URL(fileURLWithPath: "\(outputPrefix)-metrics.json"), options: .atomic)
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("cannot write metrics: \(error.localizedDescription)")
}
