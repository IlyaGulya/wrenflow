import Foundation
import AVFoundation
import os.log
import FluidAudio

private let ltLog = OSLog(subsystem: "me.gulya.wrenflow", category: "LocalTranscription")

enum LocalTranscriptionState: Equatable {
    case notLoaded
    case downloading
    case compiling
    case ready
    case error(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isLoading: Bool {
        switch self {
        case .downloading, .compiling: return true
        default: return false
        }
    }
}

enum LocalTranscriptionError: LocalizedError {
    case modelNotReady
    case audioReadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Local transcription model is not ready"
        case .audioReadFailed(let msg):
            return "Failed to read audio: \(msg)"
        case .transcriptionFailed(let msg):
            return "Local transcription failed: \(msg)"
        }
    }
}

final class LocalTranscriptionService: ObservableObject, @unchecked Sendable {
    @Published var state: LocalTranscriptionState = .notLoaded

    private var asrManager: AsrManager?

    func initialize() {
        guard !state.isReady && !state.isLoading else { return }
        os_log(.info, log: ltLog, "initialize() — starting model download/load")
        state = .downloading

        Task {
            do {
                os_log(.info, log: ltLog, "downloading model files...")
                let targetDir = try await AsrModels.download(version: .v3)
                await MainActor.run { self.state = .compiling }

                os_log(.info, log: ltLog, "model files downloaded, loading/compiling CoreML models...")
                let models = try await AsrModels.load(from: targetDir, version: .v3)
                os_log(.info, log: ltLog, "models loaded, initializing AsrManager")
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: models)
                await MainActor.run {
                    self.asrManager = manager
                    self.state = .ready
                }
                os_log(.info, log: ltLog, "AsrManager ready")
            } catch {
                os_log(.error, log: ltLog, "model initialization failed: %{public}@", error.localizedDescription)
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let manager = asrManager, state.isReady else {
            throw LocalTranscriptionError.modelNotReady
        }

        os_log(.info, log: ltLog, "transcribe() starting for file: %{public}@", fileURL.lastPathComponent)
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await manager.transcribe(fileURL)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            os_log(.info, log: ltLog, "transcription completed in %.1fms: '%{public}@'", elapsed, result.text)
            return result.text
        } catch {
            os_log(.error, log: ltLog, "transcription failed: %{public}@", error.localizedDescription)
            throw LocalTranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }
}
