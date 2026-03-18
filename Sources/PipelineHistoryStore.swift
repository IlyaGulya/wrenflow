import Foundation

final class PipelineHistoryStore {
    private let store: FfiHistoryStore?

    init() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Wrenflow"
        let dbPath: String? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map { appSupport in
            let baseURL = appSupport.appendingPathComponent(appName, isDirectory: true)
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            return baseURL.appendingPathComponent("history.sqlite").path
        }

        if let dbPath {
            do {
                store = try FfiHistoryStore(dbPath: dbPath)
            } catch {
                print("[PipelineHistoryStore] Failed to open Rust history store at \(dbPath): \(error)")
                store = nil
            }
        } else {
            print("[PipelineHistoryStore] Could not determine Application Support path.")
            store = nil
        }
    }

    func loadAllHistory() -> [PipelineHistoryItem] {
        guard let store else { return [] }
        do {
            let entries = try store.loadAll()
            return entries.compactMap { $0.toPipelineHistoryItem() }
        } catch {
            print("[PipelineHistoryStore] loadAll failed: \(error)")
            return []
        }
    }

    func append(_ item: PipelineHistoryItem, maxCount: Int) throws -> [String] {
        guard let store else { return [] }
        try store.insert(entry: item.toHistoryEntry())
        return try trim(to: maxCount)
    }

    func delete(id: UUID) throws -> String? {
        guard let store else { return nil }
        return try store.delete(id: id.uuidString.uppercased())
    }

    func clearAll() throws -> [String] {
        guard let store else { return [] }
        return try store.clearAll()
    }

    func trim(to maxCount: Int) throws -> [String] {
        guard let store else { return [] }
        guard maxCount > 0 else {
            return try clearAll()
        }
        return try store.trim(maxCount: UInt32(maxCount))
    }
}

// MARK: - PipelineHistoryItem -> HistoryEntry conversion

private extension PipelineHistoryItem {
    func toHistoryEntry() -> HistoryEntry {
        let metricsJson: String
        if metrics.isEmpty {
            metricsJson = "{}"
        } else if let data = try? JSONEncoder().encode(metrics),
                  let json = String(data: data, encoding: .utf8) {
            metricsJson = json
        } else {
            metricsJson = "{}"
        }

        return HistoryEntry(
            id: id.uuidString.uppercased(),
            timestamp: timestamp.timeIntervalSince1970,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            postProcessingReasoning: postProcessingReasoning,
            contextSummary: contextSummary,
            contextPrompt: contextPrompt,
            contextScreenshotDataUrl: contextScreenshotDataURL,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: postProcessingStatus,
            debugStatus: debugStatus,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName,
            metricsJson: metricsJson
        )
    }
}
