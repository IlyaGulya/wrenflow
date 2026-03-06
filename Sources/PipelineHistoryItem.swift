import Foundation

// MARK: - Flexible Metrics Storage

enum MetricValue: Equatable {
    case double(Double)
    case int(Int)
    case string(String)
    case bool(Bool)

    var displayValue: String {
        switch self {
        case .double(let v):
            if v >= 1000 {
                return String(format: "%.1fs", v / 1000)
            } else {
                return String(format: "%.1fms", v)
            }
        case .int(let v): return "\(v)"
        case .string(let v): return v
        case .bool(let v): return v ? "true" : "false"
        }
    }
}

extension MetricValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .double(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
}

struct PipelineMetrics: Codable, Equatable {
    private var storage: [String: MetricValue] = [:]

    subscript(key: String) -> MetricValue? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    func double(_ key: String) -> Double? {
        if case .double(let v) = storage[key] { return v }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case .int(let v) = storage[key] { return v }
        return nil
    }

    func string(_ key: String) -> String? {
        if case .string(let v) = storage[key] { return v }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let v) = storage[key] { return v }
        return nil
    }

    mutating func set(_ key: String, _ value: Double?) {
        if let value { storage[key] = .double(value) }
    }

    mutating func set(_ key: String, _ value: Int?) {
        if let value { storage[key] = .int(value) }
    }

    mutating func set(_ key: String, _ value: String?) {
        if let value { storage[key] = .string(value) }
    }

    mutating func set(_ key: String, _ value: Bool?) {
        if let value { storage[key] = .bool(value) }
    }

    var isEmpty: Bool { storage.isEmpty }

    var allKeys: [String] { storage.keys.sorted() }
}

// MARK: - Pipeline History Item

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
    let metrics: PipelineMetrics

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
        metrics: PipelineMetrics = PipelineMetrics()
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
        self.metrics = metrics
    }
}
