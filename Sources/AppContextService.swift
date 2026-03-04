import Foundation
import ApplicationServices
import AppKit
import ScreenCaptureKit

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let contextPrompt: String?
    let screenshotDataURL: String?
    let screenshotMimeType: String?
    let screenshotError: String?
    let screenshotDurationMs: Double?
    let llmInferenceDurationMs: Double?
    let totalCaptureDurationMs: Double?
    let screenshotWindowListMs: Double?
    let screenshotWindowSearchMs: Double?
    let screenshotCaptureMs: Double?
    let screenshotScContentMs: Double?
    let screenshotEncodeMs: Double?
    let screenshotMethod: String?
    let screenshotImageWidth: Int?
    let screenshotImageHeight: Int?

    var contextSummary: String {
        currentActivity
    }
}

final class AppContextService {
    static let defaultContextPrompt = """
You are a context synthesis assistant for a speech-to-text pipeline.
Given app/window metadata and an optional screenshot, output exactly two sentences that describe what the user is doing right now and the likely writing intent in the current window.
Prioritize concrete details only from the context: for email, identify recipients, subject or thread cues, and whether the user is replying or composing; for terminal/code/text work, identify the active command, file, document title, or topic.
If details are missing, state uncertainty instead of inventing facts.
Return only two sentences, no labels, no markdown, no extra commentary.
"""
    static let defaultContextPromptDate = "2026-02-24"

    private let apiKey: String
    private let baseURL: String
    private let customContextPrompt: String
    private let fallbackTextModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let visionModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private let maxScreenshotDataURILength = 500_000
    private let screenshotCompressionPrimary = 0.5
    private let screenshotMaxDimension: CGFloat = 1024

    init(apiKey: String, baseURL: String = "https://api.groq.com/openai/v1", customContextPrompt: String = "") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.customContextPrompt = customContextPrompt
    }

    func collectContext() async -> AppContext {
        let captureStart = CFAbsoluteTimeGetCurrent()

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            let totalMs = (CFAbsoluteTimeGetCurrent() - captureStart) * 1000
            return AppContext(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                currentActivity: "You are dictating in an unrecognized context.",
                contextPrompt: nil,
                screenshotDataURL: nil,
                screenshotMimeType: nil,
                screenshotError: "No frontmost application",
                screenshotDurationMs: nil,
                llmInferenceDurationMs: nil,
                totalCaptureDurationMs: totalMs,
                screenshotWindowListMs: nil,
                screenshotWindowSearchMs: nil,
                screenshotCaptureMs: nil,
                screenshotScContentMs: nil,
                screenshotEncodeMs: nil,
                screenshotMethod: nil,
                screenshotImageWidth: nil,
                screenshotImageHeight: nil
            )
        }

        let appName = frontmostApp.localizedName
        let bundleIdentifier = frontmostApp.bundleIdentifier
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        let windowTitle = focusedWindowTitle(from: appElement) ?? appName
        let selectedText = selectedText(from: appElement)

        let screenshot = await captureActiveWindowScreenshot(
            processIdentifier: frontmostApp.processIdentifier,
            appElement: appElement,
            focusedWindowTitle: windowTitle
        )
        let screenshotDurationMs = screenshot.timings.totalMs

        let currentActivity: String
        let contextPrompt: String?
        var llmInferenceDurationMs: Double? = nil
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let llmStart = CFAbsoluteTimeGetCurrent()
            if let result = await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: screenshot.dataURL
            ) {
                llmInferenceDurationMs = (CFAbsoluteTimeGetCurrent() - llmStart) * 1000
                currentActivity = result.activity
                contextPrompt = result.prompt
            } else {
                llmInferenceDurationMs = (CFAbsoluteTimeGetCurrent() - llmStart) * 1000
                currentActivity = fallbackCurrentActivity(
                    appName: appName,
                    bundleIdentifier: bundleIdentifier,
                    selectedText: selectedText,
                    windowTitle: windowTitle,
                    screenshotAvailable: screenshot.dataURL != nil
                )
                contextPrompt = nil
            }
        } else {
            currentActivity = fallbackCurrentActivity(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                selectedText: selectedText,
                windowTitle: windowTitle,
                screenshotAvailable: screenshot.dataURL != nil
            )
            contextPrompt = nil
        }

        let totalCaptureDurationMs = (CFAbsoluteTimeGetCurrent() - captureStart) * 1000

        return AppContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            currentActivity: currentActivity,
            contextPrompt: contextPrompt,
            screenshotDataURL: screenshot.dataURL,
            screenshotMimeType: screenshot.mimeType,
            screenshotError: screenshot.error,
            screenshotDurationMs: screenshotDurationMs,
            llmInferenceDurationMs: llmInferenceDurationMs,
            totalCaptureDurationMs: totalCaptureDurationMs,
            screenshotWindowListMs: screenshot.timings.windowListMs,
            screenshotWindowSearchMs: screenshot.timings.windowSearchMs,
            screenshotCaptureMs: screenshot.timings.captureMs,
            screenshotScContentMs: screenshot.timings.scContentMs,
            screenshotEncodeMs: screenshot.timings.encodeMs,
            screenshotMethod: screenshot.timings.method.isEmpty ? nil : screenshot.timings.method,
            screenshotImageWidth: screenshot.timings.imageWidth > 0 ? screenshot.timings.imageWidth : nil,
            screenshotImageHeight: screenshot.timings.imageHeight > 0 ? screenshot.timings.imageHeight : nil
        )
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?
    ) async -> (activity: String, prompt: String)? {
        let modelsToTry = [
            screenshotDataURL != nil ? visionModel : fallbackTextModel,
            fallbackTextModel
        ]

        for model in modelsToTry {
            let screenshotPayload = model == visionModel ? screenshotDataURL : nil
            if let inferred = await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: screenshotPayload,
                model: model
            ) {
                return inferred
            }
        }

        return nil
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?,
        model: String
    ) async -> (activity: String, prompt: String)? {
        do {
            var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let metadata = """
App: \(appName ?? "Unknown")
Bundle ID: \(bundleIdentifier ?? "Unknown")
Window: \(windowTitle ?? "Unknown")
Selected text: \(selectedText ?? "None")
"""

            let systemPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultContextPrompt
                : customContextPrompt

            let textOnlyPrompt = "Analyze the context and infer the user's current activity in exactly two sentences.\n\n\(metadata)"
            var userMessageDescription: String
            var userMessage: Any = textOnlyPrompt

            if let screenshotDataURL {
                userMessageDescription = "[screenshot attached]\nAnalyze the screenshot plus metadata to infer current activity.\n\(metadata)"
                userMessage = [
                    [
                        "type": "text",
                        "text": "Analyze the screenshot plus metadata to infer current activity."
                    ],
                    [
                        "type": "text",
                        "text": metadata
                    ],
                    [
                        "type": "image_url",
                        "image_url": ["url": screenshotDataURL]
                    ]
                ]
            } else {
                userMessageDescription = textOnlyPrompt
            }

            let fullPrompt = "Model: \(model)\n\n[System]\n\(systemPrompt)\n[User]\n\(userMessageDescription)"

            let payload: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }

            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return (activity: normalizedActivitySummary(cleaned), prompt: fullPrompt)
        } catch {
            return nil
        }
    }

    private func normalizedActivitySummary(_ value: String) -> String {
        let sentences = value
            .split(whereSeparator: { $0 == "." || $0 == "。" || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count <= 2 {
            return value
        }

        let firstTwo = sentences.prefix(2)
        return firstTwo.joined(separator: ". ") + "."
    }

    private func fallbackCurrentActivity(
        appName: String?,
        bundleIdentifier: String?,
        selectedText: String?,
        windowTitle: String?,
        screenshotAvailable: Bool
    ) -> String {
        let activeApp = appName ?? "the active application"
        if screenshotAvailable {
            return "Could not reliably infer a two-sentence summary for \(activeApp) from the screenshot and metadata."
        }
        return "Could not reliably infer a two-sentence summary for \(activeApp) from the visible metadata."
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        if let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) {
            return trimmedText(windowTitle)
        }

        return nil
    }

    private func selectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let selectedText = accessibilityString(from: focusedElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        if let selectedText = accessibilityString(from: appElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        return nil
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return trimmedText(stringValue)
    }

    private func accessibilityPoint(from element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func accessibilitySize(from element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    struct ScreenshotTimings {
        var windowListMs: Double = 0
        var windowSearchMs: Double = 0
        var scContentMs: Double = 0
        var captureMs: Double = 0
        var encodeMs: Double = 0
        var totalMs: Double = 0
        var method: String = ""
        var imageWidth: Int = 0
        var imageHeight: Int = 0
    }

    private func captureActiveWindowScreenshot(
        processIdentifier: pid_t,
        appElement: AXUIElement,
        focusedWindowTitle: String?
    ) async -> (dataURL: String?, mimeType: String?, error: String?, timings: ScreenshotTimings) {
        let totalStart = CFAbsoluteTimeGetCurrent()
        var timings = ScreenshotTimings()

        if !CGPreflightScreenCaptureAccess() {
            timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            return (
                nil,
                nil,
                "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording.",
                timings
            )
        }

        let windowListStart = CFAbsoluteTimeGetCurrent()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        timings.windowListMs = (CFAbsoluteTimeGetCurrent() - windowListStart) * 1000

        guard let windows else {
            timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            return (nil, nil, "Unable to read window list", timings)
        }

        let ownerPIDKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let onScreenKey = kCGWindowIsOnscreen as String
        let windowIDKey = kCGWindowNumber as String
        let boundsKey = kCGWindowBounds as String
        let nameKey = kCGWindowName as String

        struct CandidateWindow {
            let id: CGWindowID
            let layer: Int
            let area: Int
            let bounds: CGRect?
            let name: String?
        }

        let searchStart = CFAbsoluteTimeGetCurrent()
        let candidateWindows = windows.compactMap { windowInfo -> CandidateWindow? in
            guard let ownerPID = windowInfo[ownerPIDKey] as? Int,
                  ownerPID == processIdentifier else {
                return nil
            }
            guard let isOnScreen = windowInfo[onScreenKey] as? Bool, isOnScreen else { return nil }
            guard let windowIDValue = windowInfo[windowIDKey] as? Int else { return nil }
            let layer = (windowInfo[layerKey] as? Int) ?? 0
            let bounds = boundsRect(windowInfo[boundsKey])
            let width = bounds?.width ?? 1
            let height = bounds?.height ?? 1
            let area = Int(width * height)
            let name = trimmedText(windowInfo[nameKey] as? String)

            return CandidateWindow(
                id: CGWindowID(windowIDValue),
                layer: layer,
                area: area,
                bounds: bounds,
                name: name
            )
        }

        // Find the target window ID using bounds matching or title matching
        var targetWindowID: CGWindowID?

        if let focusedWindowBounds = focusedWindowBounds(from: appElement), !focusedWindowBounds.isNull {
            if let activeWindow = candidateWindows
                .compactMap({ candidate -> (CandidateWindow, CGFloat)? in
                    guard let candidateBounds = candidate.bounds else { return nil }
                    let intersection = candidateBounds.intersection(focusedWindowBounds)
                    guard !intersection.isNull else { return nil }
                    let overlap = intersection.width * intersection.height
                    return (candidate, overlap)
                })
                .sorted(by: { lhs, rhs in
                    if lhs.0.layer == rhs.0.layer {
                        return lhs.1 > rhs.1
                    }
                    return lhs.0.layer < rhs.0.layer
                })
                .first?.0 {
                timings.windowSearchMs = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000
                timings.method = "bounds"
                targetWindowID = activeWindow.id
            }
        }

        if targetWindowID == nil, let focusedWindowTitle {
            if let activeWindow = candidateWindows
                .filter({ candidate in
                    let normalizedName = candidate.name?
                        .lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedTarget = focusedWindowTitle
                        .lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let normalizedName, !normalizedName.isEmpty,
                          !normalizedTarget.isEmpty else {
                        return false
                    }
                    return normalizedName == normalizedTarget || normalizedName.contains(normalizedTarget)
                })
                .sorted(by: { lhs, rhs in
                    if lhs.layer == rhs.layer {
                        return lhs.area > rhs.area
                    }
                    return lhs.layer < rhs.layer
                })
                .first {
                timings.windowSearchMs = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000
                timings.method = "title"
                targetWindowID = activeWindow.id
            }
        }

        if timings.windowSearchMs == 0 {
            timings.windowSearchMs = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000
        }

        // Get SCShareableContent for ScreenCaptureKit capture
        let scContentStart = CFAbsoluteTimeGetCurrent()
        let scContent: SCShareableContent
        do {
            scContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            timings.scContentMs = (CFAbsoluteTimeGetCurrent() - scContentStart) * 1000
            timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            return (nil, nil, "Could not get shareable content: \(error.localizedDescription)", timings)
        }
        timings.scContentMs = (CFAbsoluteTimeGetCurrent() - scContentStart) * 1000

        // Try window capture via ScreenCaptureKit
        if let targetWindowID {
            if let scWindow = scContent.windows.first(where: { $0.windowID == targetWindowID }) {
                let captureStart = CFAbsoluteTimeGetCurrent()
                do {
                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let config = SCStreamConfiguration()
                    config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                    config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                    config.ignoreShadowsSingleWindow = true
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    timings.captureMs = (CFAbsoluteTimeGetCurrent() - captureStart) * 1000
                    timings.imageWidth = image.width
                    timings.imageHeight = image.height

                    let encodeStart = CFAbsoluteTimeGetCurrent()
                    if let dataURL = convertImageToDataURL(
                        image,
                        mimeType: "image/jpeg",
                        fileType: .jpeg,
                        compression: screenshotCompressionPrimary,
                        maxDimension: screenshotMaxDimension
                    ) {
                        timings.encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000
                        timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
                        return (dataURL, "image/jpeg", nil, timings)
                    }
                } catch {
                    // Fall through to fullscreen capture
                }
            }
        }

        // Fullscreen fallback via ScreenCaptureKit display capture
        timings.method = timings.method.isEmpty ? "fullscreen" : timings.method
        let mouseLocation = NSEvent.mouseLocation
        let targetDisplay = scContent.displays.first { display in
            let frame = display.frame
            return frame.contains(CGPoint(x: mouseLocation.x, y: mouseLocation.y))
        } ?? scContent.displays.first

        guard let display = targetDisplay else {
            timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            return (nil, nil, "No display found for screenshot", timings)
        }

        let captureStart = CFAbsoluteTimeGetCurrent()
        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.frame.width) * Int(display.frame.width > 2560 ? 2 : 1)
            config.height = Int(display.frame.height) * Int(display.frame.width > 2560 ? 2 : 1)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            timings.captureMs = (CFAbsoluteTimeGetCurrent() - captureStart) * 1000
            timings.imageWidth = image.width
            timings.imageHeight = image.height

            let encodeStart = CFAbsoluteTimeGetCurrent()
            if let dataURL = convertImageToDataURL(
                image,
                mimeType: "image/jpeg",
                fileType: .jpeg,
                compression: screenshotCompressionPrimary,
                maxDimension: screenshotMaxDimension
            ) {
                timings.encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000
                timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
                return (dataURL, "image/jpeg", nil, timings)
            }
        } catch {
            timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            return (nil, nil, "Could not capture screenshot: \(error.localizedDescription)", timings)
        }

        timings.totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
        return (nil, nil, "Could not capture screenshot within size limits", timings)
    }

    private func boundsValue(_ value: Any?) -> CGSize? {
        guard let bounds = value as? [String: Any],
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private func boundsRect(_ value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func focusedWindowBounds(from appElement: AXUIElement) -> CGRect? {
        guard let focusedWindow = accessibilityElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ),
              let point = accessibilityPoint(from: focusedWindow, attribute: kAXPositionAttribute as CFString),
              let size = accessibilitySize(from: focusedWindow, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private func convertImageToDataURL(
        _ image: CGImage,
        mimeType: String,
        fileType: NSBitmapImageRep.FileType,
        compression: Double?,
        maxDimension: CGFloat?
    ) -> String? {
        let compressionSteps: [Double] = if let compression {
            [compression, compression * 0.5, compression * 0.25]
        } else {
            [1.0]
        }
        let dimensionSteps: [CGFloat?] = if let maxDimension {
            [maxDimension, maxDimension * 0.75, maxDimension * 0.5]
        } else {
            [nil]
        }

        for dim in dimensionSteps {
            let imageToEncode = dim.flatMap { resizedImage(for: image, maxDimension: $0) } ?? image
            let rep = NSBitmapImageRep(cgImage: imageToEncode)

            for comp in compressionSteps {
                guard let imageData = rep.representation(
                    using: fileType,
                    properties: [.compressionFactor: comp]
                ) else { continue }

                let base64 = imageData.base64EncodedString()
                if base64.count <= maxScreenshotDataURILength {
                    return "data:\(mimeType);base64,\(base64)"
                }
            }
        }

        return nil
    }

    private func resizedImage(for image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        guard width > maxDimension || height > maxDimension else {
            return image
        }

        let scale = min(maxDimension / width, maxDimension / height, 1.0)
        let targetSize = CGSize(width: width * scale, height: height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage()
    }

    private func trimmedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }
}
