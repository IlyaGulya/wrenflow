import Foundation

struct PipelineHistoryItem: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let rawTranscript: String
    let postProcessedTranscript: String
    let postProcessingPrompt: String?
    let postProcessingReasoning: String?
    let contextSummary: String
    let contextPrompt: String?
    let contextScreenshotDataURL: String?
    let contextScreenshotStatus: String
    let postProcessingStatus: String
    let debugStatus: String
    let customVocabulary: String
    let audioFileName: String?
    let transcriptionDurationMs: Double?
    let contextDurationMs: Double?
    let postProcessingDurationMs: Double?
    let totalDurationMs: Double?
    let recordingDurationMs: Double?
    let audioFileSizeBytes: Int64?
    let contextCaptureDurationMs: Double?
    let contextScreenshotDurationMs: Double?
    let contextLlmInferenceDurationMs: Double?
    let transcriptionProvider: String?
    let postProcessingModel: String?
    let pasteDurationMs: Double?
    let screenshotWindowListMs: Double?
    let screenshotWindowSearchMs: Double?
    let screenshotCaptureMs: Double?
    let screenshotScContentMs: Double?
    let screenshotEncodeMs: Double?
    let screenshotMethod: String?
    let screenshotImageWidth: Int?
    let screenshotImageHeight: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String?,
        postProcessingReasoning: String? = nil,
        contextSummary: String,
        contextPrompt: String?,
        contextScreenshotDataURL: String?,
        contextScreenshotStatus: String,
        postProcessingStatus: String,
        debugStatus: String,
        customVocabulary: String,
        audioFileName: String? = nil,
        transcriptionDurationMs: Double? = nil,
        contextDurationMs: Double? = nil,
        postProcessingDurationMs: Double? = nil,
        totalDurationMs: Double? = nil,
        recordingDurationMs: Double? = nil,
        audioFileSizeBytes: Int64? = nil,
        contextCaptureDurationMs: Double? = nil,
        contextScreenshotDurationMs: Double? = nil,
        contextLlmInferenceDurationMs: Double? = nil,
        transcriptionProvider: String? = nil,
        postProcessingModel: String? = nil,
        pasteDurationMs: Double? = nil,
        screenshotWindowListMs: Double? = nil,
        screenshotWindowSearchMs: Double? = nil,
        screenshotCaptureMs: Double? = nil,
        screenshotScContentMs: Double? = nil,
        screenshotEncodeMs: Double? = nil,
        screenshotMethod: String? = nil,
        screenshotImageWidth: Int? = nil,
        screenshotImageHeight: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.postProcessedTranscript = postProcessedTranscript
        self.postProcessingPrompt = postProcessingPrompt
        self.postProcessingReasoning = postProcessingReasoning
        self.contextSummary = contextSummary
        self.contextPrompt = contextPrompt
        self.contextScreenshotDataURL = contextScreenshotDataURL
        self.contextScreenshotStatus = contextScreenshotStatus
        self.postProcessingStatus = postProcessingStatus
        self.debugStatus = debugStatus
        self.customVocabulary = customVocabulary
        self.audioFileName = audioFileName
        self.transcriptionDurationMs = transcriptionDurationMs
        self.contextDurationMs = contextDurationMs
        self.postProcessingDurationMs = postProcessingDurationMs
        self.totalDurationMs = totalDurationMs
        self.recordingDurationMs = recordingDurationMs
        self.audioFileSizeBytes = audioFileSizeBytes
        self.contextCaptureDurationMs = contextCaptureDurationMs
        self.contextScreenshotDurationMs = contextScreenshotDurationMs
        self.contextLlmInferenceDurationMs = contextLlmInferenceDurationMs
        self.transcriptionProvider = transcriptionProvider
        self.postProcessingModel = postProcessingModel
        self.pasteDurationMs = pasteDurationMs
        self.screenshotWindowListMs = screenshotWindowListMs
        self.screenshotWindowSearchMs = screenshotWindowSearchMs
        self.screenshotCaptureMs = screenshotCaptureMs
        self.screenshotScContentMs = screenshotScContentMs
        self.screenshotEncodeMs = screenshotEncodeMs
        self.screenshotMethod = screenshotMethod
        self.screenshotImageWidth = screenshotImageWidth
        self.screenshotImageHeight = screenshotImageHeight
    }
}
