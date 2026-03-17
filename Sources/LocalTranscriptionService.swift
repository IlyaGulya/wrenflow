import Foundation
import os.log

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

/// Local transcription using Rust parakeet-rs via FFI.
/// Replaces the previous FluidAudio (CoreML) implementation.
final class LocalTranscriptionService: ObservableObject, @unchecked Sendable {
    @Published var state: LocalTranscriptionState = .notLoaded

    #if canImport(wrenflow_ffiFFI)
    private var engine: FfiLocalTranscriptionEngine?
    #endif

    /// Model directory path (parakeet-rs downloads/caches models here).
    private var modelDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Wrenflow/Models/parakeet-tdt"
    }

    func initialize() {
        guard !state.isReady && !state.isLoading else { return }
        os_log(.info, log: ltLog, "initialize() — loading model via Rust parakeet-rs")
        state = .compiling

        #if canImport(wrenflow_ffiFFI)
        Task.detached { [weak self] in
            guard let self else { return }
            let eng = FfiLocalTranscriptionEngine()

            // Create model dir if needed
            try? FileManager.default.createDirectory(
                atPath: self.modelDir, withIntermediateDirectories: true)

            if let error = eng.initialize(modelDir: self.modelDir) {
                os_log(.error, log: ltLog, "model init failed: %{public}@", error)
                await MainActor.run {
                    self.state = .error(error)
                }
            } else {
                os_log(.info, log: ltLog, "model ready")
                await MainActor.run {
                    self.engine = eng
                    self.state = .ready
                }
            }
        }
        #else
        state = .error("Rust FFI not available — local transcription disabled")
        #endif
    }

    func transcribe(fileURL: URL) async throws -> String {
        #if canImport(wrenflow_ffiFFI)
        guard let engine = engine, state.isReady else {
            throw LocalTranscriptionError.modelNotReady
        }

        os_log(.info, log: ltLog, "transcribe() starting for: %{public}@", fileURL.lastPathComponent)
        let start = CFAbsoluteTimeGetCurrent()

        let result = engine.transcribeFile(filePath: fileURL.path)
        if let error = result.error {
            os_log(.error, log: ltLog, "transcription failed: %{public}@", error)
            throw LocalTranscriptionError.transcriptionFailed(error)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        os_log(.info, log: ltLog, "transcription done in %.1fms: '%{public}@'", elapsed, result.text)
        return result.text
        #else
        throw LocalTranscriptionError.transcriptionFailed("Rust FFI not available")
        #endif
    }
}
