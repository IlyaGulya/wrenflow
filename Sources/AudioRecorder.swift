import AVFoundation
import CoreAudio
import Foundation
import os.log

private let recordingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Recording")

struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func availableInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [AudioDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputStreamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputStreamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            let bufferListRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(streamSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListRaw.deallocate() }
            let bufferListPointer = bufferListRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
            guard AudioObjectGetPropertyData(deviceID, &inputStreamAddress, 0, nil, &streamSize, bufferListPointer) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let uidRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(uidSize),
                alignment: MemoryLayout<CFString?>.alignment
            )
            defer { uidRaw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidRaw) == noErr else { continue }
            guard let uidRef = uidRaw.load(as: CFString?.self) else { continue }
            let uid = uidRef as String
            guard !uid.isEmpty else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let nameRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(nameSize),
                alignment: MemoryLayout<CFString?>.alignment
            )
            defer { nameRaw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, nameRaw) == noErr else { continue }
            guard let nameRef = nameRaw.load(as: CFString?.self) else { continue }
            let name = nameRef as String
            guard !name.isEmpty else { continue }

            devices.append(AudioDevice(id: deviceID, uid: uid, name: name))
        }
        return devices
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }
}

struct RecordingResult {
    let fileURL: URL
    let durationMs: Double
    let fileSizeBytes: Int64
    // Engine metrics
    let engineInitMs: Double?
    let engineReused: Bool
    let engineWarmedUp: Bool
    let engineStartMs: Double?        // just the engine.start() call duration
    let inputSampleRate: Double
    // Buffer metrics
    let bufferCount: Int
    let firstTapCallbackMs: Double?   // first tap callback of any kind
    let firstNonSilentBufferMs: Double? // first buffer with rms > 0
    let firstBufferFrames: Int?       // frameLength of first buffer
    // HAL metrics
    let halBufferFrames: Int?         // HAL buffer frame size of device
    let halBufferDurationMs: Double?  // HAL buffer duration in ms
    let halMinFrames: Int?            // min allowed HAL buffer size
    let halMaxFrames: Int?            // max allowed HAL buffer size
    let halBufferSetTo: Int?          // what we tried to set it to (nil if unchanged)
    let halBufferActual: Int?         // actual value after set attempt
    // Timing checkpoints
    let armedMs: Double?              // when _recording=true relative to start
    let fileReadyMs: Double?          // when file/converter ready relative to start
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        }
    }
}

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private let audioFileQueue = DispatchQueue(label: "com.zachlatta.freeflow.audiofile")
    private var recordingStartTime: CFAbsoluteTime = 0
    private var firstBufferLogged = false
    private var bufferCount: Int = 0
    private var currentDeviceUID: String?
    private var storedInputFormat: AVAudioFormat?
    private var realtimeConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    // Metrics tracking
    private var engineInitMs: Double?
    private var engineReused: Bool = false
    private var engineStartMs: Double?
    private var firstTapCallbackMs: Double?
    private var firstNonSilentBufferMs: Double?
    private var firstBufferFrames: Int?
    private var wasWarmedUp: Bool = false
    private var armedMs: Double?
    private var fileReadyMs: Double?
    private var firstTapCallbackFired = false
    // HAL info
    private var halBufferFrames: Int?
    private var halMinFrames: Int?
    private var halMaxFrames: Int?
    private var halBufferSetTo: Int?
    private var halBufferActual: Int?
    /// Resolved CoreAudio device ID for the current input device.
    private var resolvedDeviceID: AudioDeviceID?

    @Published var isRecording = false
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.0

    var onRecordingReady: (() -> Void)?
    private var readyFired = false

    // MARK: - HAL Buffer Size Helpers

    private static func getHALBufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var frameSize: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &frameSize)
        return status == noErr ? frameSize : nil
    }

    private static func getHALBufferFrameSizeRange(deviceID: AudioDeviceID) -> (min: UInt32, max: UInt32)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var dataSize = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &range)
        return status == noErr ? (min: UInt32(range.mMinimum), max: UInt32(range.mMaximum)) : nil
    }

    private static func setHALBufferFrameSize(deviceID: AudioDeviceID, frames: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frames
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }

    /// Read and log HAL buffer info for the resolved device; try to set a smaller buffer.
    private func probeAndOptimizeHALBuffer() {
        guard let deviceID = resolvedDeviceID else { return }
        let sampleRate = storedInputFormat?.sampleRate ?? 44100

        // Read current HAL buffer frame size
        if let currentFrames = Self.getHALBufferFrameSize(deviceID: deviceID) {
            halBufferFrames = Int(currentFrames)
            let durationMs = Double(currentFrames) / sampleRate * 1000
            os_log(.info, log: recordingLog, "HAL buffer: %d frames (%.1fms @ %.0fHz)",
                   currentFrames, durationMs, sampleRate)
        }

        // Read allowed range
        if let range = Self.getHALBufferFrameSizeRange(deviceID: deviceID) {
            halMinFrames = Int(range.min)
            halMaxFrames = Int(range.max)
            os_log(.info, log: recordingLog, "HAL buffer range: %d–%d frames (%.1f–%.1fms)",
                   range.min, range.max,
                   Double(range.min) / sampleRate * 1000,
                   Double(range.max) / sampleRate * 1000)

            // Try to set a smaller buffer if current is larger than minimum
            let currentFrames = UInt32(halBufferFrames ?? 0)
            if currentFrames > range.min {
                // Try power-of-2 steps: 128, 256, 512
                let candidates: [UInt32] = [128, 256, 512]
                let target = candidates.first { $0 >= range.min } ?? range.min
                halBufferSetTo = Int(target)
                os_log(.info, log: recordingLog, "HAL buffer: attempting to set %d frames (min=%d)",
                       target, range.min)

                if Self.setHALBufferFrameSize(deviceID: deviceID, frames: target) {
                    // Re-read to verify
                    if let actual = Self.getHALBufferFrameSize(deviceID: deviceID) {
                        halBufferActual = Int(actual)
                        let actualMs = Double(actual) / sampleRate * 1000
                        os_log(.info, log: recordingLog, "HAL buffer SET: requested=%d, actual=%d frames (%.1fms)",
                               target, actual, actualMs)
                    }
                } else {
                    os_log(.error, log: recordingLog, "HAL buffer: failed to set %d frames", target)
                    halBufferActual = halBufferFrames
                }
            } else {
                os_log(.info, log: recordingLog, "HAL buffer: already at minimum (%d frames)", currentFrames)
            }
        }
    }

    // MARK: - Engine Setup (shared between warmUp and startRecording cold path)

    private func setupEngine(deviceUID: String?) throws -> AVAudioEngine {
        let engine = AVAudioEngine()

        // Set specific input device if requested
        if let uid = deviceUID, !uid.isEmpty, uid != "default",
           let deviceID = AudioDevice.deviceID(forUID: uid) {
            resolvedDeviceID = deviceID
            let inputUnit = engine.inputNode.audioUnit!
            var id = deviceID
            AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        } else {
            // Resolve default device ID for HAL queries
            resolvedDeviceID = resolveDefaultInputDeviceID()
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat("Invalid sample rate: \(inputFormat.sampleRate)")
        }
        guard inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat("No input channels available")
        }

        storedInputFormat = inputFormat

        // Install tap — buffers are discarded until _recording is true
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Track first tap callback regardless of _recording state
            if !self.firstTapCallbackFired {
                self.firstTapCallbackFired = true
                let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                self.firstTapCallbackMs = elapsed
                self.firstBufferFrames = Int(buffer.frameLength)
                os_log(.info, log: recordingLog, "FIRST tap callback at %.3fms, frames=%d", elapsed, buffer.frameLength)
            }

            guard self._recording.withLock({ $0 }) else { return }

            self.bufferCount += 1

            var rms: Float = 0
            let frames = Int(buffer.frameLength)
            if frames > 0, let channelData = buffer.floatChannelData {
                let samples = channelData[0]
                var sum: Float = 0
                for i in 0..<frames { sum += samples[i] * samples[i] }
                rms = sqrtf(sum / Float(frames))
            }

            if self.bufferCount <= 40 {
                let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                os_log(.info, log: recordingLog, "buffer #%d at %.3fms, frames=%d, rms=%.6f", self.bufferCount, elapsed, buffer.frameLength, rms)
            }

            // Fire ready callback on first non-silent buffer
            if !self.readyFired && rms > 0 {
                self.readyFired = true
                let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                self.firstNonSilentBufferMs = elapsed
                os_log(.info, log: recordingLog, "FIRST non-silent buffer at %.3fms — recording ready", elapsed)
                self.onRecordingReady?()
            }

            // Convert to 16kHz mono and write
            self.audioFileQueue.sync {
                if let file = self.audioFile, let converter = self.realtimeConverter, let targetFmt = self.targetFormat {
                    let ratio = targetFmt.sampleRate / buffer.format.sampleRate
                    let convertedCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: convertedCapacity) else { return }
                    var error: NSError?
                    var consumed = false
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if let error {
                        os_log(.error, log: recordingLog, "realtime conversion error at buffer #%d: %{public}@", self.bufferCount, error.localizedDescription)
                    } else if convertedBuffer.frameLength > 0 {
                        do {
                            try file.write(from: convertedBuffer)
                        } catch {
                            os_log(.error, log: recordingLog, "ERROR writing buffer #%d to file: %{public}@", self.bufferCount, error.localizedDescription)
                            self.audioFile = nil
                        }
                    }
                } else if self.bufferCount <= 5 {
                    os_log(.error, log: recordingLog, "audioFile/converter is nil at buffer #%d — audio not being written!", self.bufferCount)
                }
            }
            self.computeAudioLevel(from: buffer)
        }

        engine.prepare()
        return engine
    }

    private func resolveDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        return status == noErr ? deviceID : nil
    }

    // MARK: - Warm Up

    func warmUp(deviceUID: String? = nil) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "warmUp() entered")

        if audioEngine != nil, currentDeviceUID == deviceUID {
            os_log(.info, log: recordingLog, "warmUp() skipped — already warm for device")
            return
        }

        if audioEngine != nil {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
        }

        guard AVCaptureDevice.default(for: .audio) != nil else {
            os_log(.error, log: recordingLog, "warmUp() — no audio input device")
            return
        }

        do {
            let engine = try setupEngine(deviceUID: deviceUID)
            self.audioEngine = engine
            self.currentDeviceUID = deviceUID

            // Probe HAL buffer info and try to optimize
            probeAndOptimizeHALBuffer()

            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            os_log(.info, log: recordingLog, "warmUp() complete: %.3fms (engine created, tap installed, prepared — NOT started)", elapsed)
        } catch {
            os_log(.error, log: recordingLog, "warmUp() failed: %{public}@", error.localizedDescription)
        }
    }

    // MARK: - Recording

    func startRecording(deviceUID: String? = nil) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0

        // Reset all per-recording metrics
        firstBufferLogged = false
        bufferCount = 0
        readyFired = false
        firstTapCallbackFired = false
        engineInitMs = nil
        engineReused = false
        engineStartMs = nil
        firstTapCallbackMs = nil
        firstNonSilentBufferMs = nil
        firstBufferFrames = nil
        wasWarmedUp = false
        armedMs = nil
        fileReadyMs = nil
        halBufferSetTo = nil
        halBufferActual = nil

        os_log(.info, log: recordingLog, "startRecording() entered")

        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioRecorderError.missingInputDevice
        }

        // Reuse existing engine if same device
        if let engine = audioEngine, currentDeviceUID == deviceUID {
            engineReused = true
            wasWarmedUp = !engine.isRunning
            os_log(.info, log: recordingLog, "reusing existing engine (warmedUp=%d, running=%d): %.3fms",
                   wasWarmedUp, engine.isRunning, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        } else {
            // Tear down old engine if device changed
            if audioEngine != nil {
                audioEngine?.inputNode.removeTap(onBus: 0)
                audioEngine?.stop()
                audioEngine = nil
            }

            let initStart = CFAbsoluteTimeGetCurrent()
            let engine = try setupEngine(deviceUID: deviceUID)
            self.audioEngine = engine
            self.currentDeviceUID = deviceUID
            self.engineInitMs = (CFAbsoluteTimeGetCurrent() - initStart) * 1000
            os_log(.info, log: recordingLog, "cold engine setup: %.3fms", engineInitMs ?? 0)
        }

        guard let inputFormat = storedInputFormat else {
            throw AudioRecorderError.invalidInputFormat("No stored input format")
        }

        // Phase 3: Prepare file and converter BEFORE engine.start() so we're armed immediately
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        self.tempFileURL = fileURL

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.invalidInputFormat("Failed to create 16kHz mono format")
        }
        self.targetFormat = outFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw AudioRecorderError.invalidInputFormat("Failed to create realtime converter from \(inputFormat) to 16kHz mono")
        }
        self.realtimeConverter = converter

        let newAudioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: outFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        audioFileQueue.sync { self.audioFile = newAudioFile }
        fileReadyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        os_log(.info, log: recordingLog, "file+converter ready: %.3fms", fileReadyMs ?? 0)

        // Arm recording — tap will start writing from next buffer
        _recording.withLock { $0 = true }
        self.isRecording = true
        armedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        os_log(.info, log: recordingLog, "recording armed: %.3fms", armedMs ?? 0)

        // Probe HAL and try to optimize (in case warmUp didn't run or device changed)
        probeAndOptimizeHALBuffer()

        // Start engine AFTER arming — so first buffer won't be missed
        if let engine = audioEngine, !engine.isRunning {
            let startT = CFAbsoluteTimeGetCurrent()
            try engine.start()
            engineStartMs = (CFAbsoluteTimeGetCurrent() - startT) * 1000
            os_log(.info, log: recordingLog, "engine.start(): %.3fms (total from entry: %.3fms)",
                   engineStartMs ?? 0, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func stopRecording() -> RecordingResult? {
        let recordingDurationMs = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received", recordingDurationMs, bufferCount)

        _recording.withLock { $0 = false }
        audioFileQueue.sync { audioFile = nil }
        isRecording = false
        smoothedLevel = 0.0
        DispatchQueue.main.async { self.audioLevel = 0.0 }

        audioEngine?.pause()
        realtimeConverter = nil
        os_log(.info, log: recordingLog, "engine paused (mic indicator off, resources retained)")

        guard let url = tempFileURL else {
            os_log(.error, log: recordingLog, "ERROR: tempFileURL is nil")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            os_log(.error, log: recordingLog, "ERROR: temp file does not exist at %{public}@", url.path)
            return nil
        }

        var fileSizeBytes: Int64 = 0
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSizeBytes = (attrs[.size] as? Int64) ?? 0
            os_log(.info, log: recordingLog, "recorded file: %{public}@, size=%lld bytes", url.lastPathComponent, fileSizeBytes)
            if fileSizeBytes == 0 {
                os_log(.error, log: recordingLog, "WARNING: recorded file is EMPTY (0 bytes)!")
            }
        } catch {
            os_log(.error, log: recordingLog, "failed to get file attributes: %{public}@", error.localizedDescription)
        }

        let halDurationMs: Double?
        if let frames = halBufferFrames, let rate = storedInputFormat?.sampleRate, rate > 0 {
            halDurationMs = Double(frames) / rate * 1000
        } else {
            halDurationMs = nil
        }

        return RecordingResult(
            fileURL: url,
            durationMs: recordingDurationMs,
            fileSizeBytes: fileSizeBytes,
            engineInitMs: engineInitMs,
            engineReused: engineReused,
            engineWarmedUp: wasWarmedUp,
            engineStartMs: engineStartMs,
            inputSampleRate: storedInputFormat?.sampleRate ?? 0,
            bufferCount: bufferCount,
            firstTapCallbackMs: firstTapCallbackMs,
            firstNonSilentBufferMs: firstNonSilentBufferMs,
            firstBufferFrames: firstBufferFrames,
            halBufferFrames: halBufferFrames,
            halBufferDurationMs: halDurationMs,
            halMinFrames: halMinFrames,
            halMaxFrames: halMaxFrames,
            halBufferSetTo: halBufferSetTo,
            halBufferActual: halBufferActual,
            armedMs: armedMs,
            fileReadyMs: fileReadyMs
        )
    }

    private func computeAudioLevel(from buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sumOfSquares: Float = 0.0
        if let channelData = buffer.floatChannelData {
            let samples = channelData[0]
            for i in 0..<frames {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
        } else if let channelData = buffer.int16ChannelData {
            let samples = channelData[0]
            for i in 0..<frames {
                let sample = Float(samples[i]) / Float(Int16.max)
                sumOfSquares += sample * sample
            }
        } else {
            return
        }

        let rms = sqrtf(sumOfSquares / Float(frames))
        let scaled = min(rms * 10.0, 1.0)

        if scaled > smoothedLevel {
            smoothedLevel = smoothedLevel * 0.3 + scaled * 0.7
        } else {
            smoothedLevel = smoothedLevel * 0.6 + scaled * 0.4
        }

        DispatchQueue.main.async {
            self.audioLevel = self.smoothedLevel
        }
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
}
