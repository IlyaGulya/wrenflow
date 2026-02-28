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
        // Look up through the enumerated devices to avoid CFString pointer issues
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }
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

    @Published var isRecording = false
    /// Thread-safe flag read from the audio tap callback.
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.0

    /// Called on the audio thread when the first non-silent buffer arrives.
    var onRecordingReady: (() -> Void)?
    private var readyFired = false

    func startRecording(deviceUID: String? = nil) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0
        firstBufferLogged = false
        bufferCount = 0
        readyFired = false

        os_log(.info, log: recordingLog, "startRecording() entered")

        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioRecorderError.missingInputDevice
        }
        os_log(.info, log: recordingLog, "AVCaptureDevice check: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        // Reuse existing engine if same device, otherwise build new one
        if let _ = audioEngine, currentDeviceUID == deviceUID {
            os_log(.info, log: recordingLog, "reusing existing engine: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        } else {
            // Tear down old engine if device changed
            if audioEngine != nil {
                audioEngine?.inputNode.removeTap(onBus: 0)
                audioEngine?.stop()
                audioEngine = nil
            }

            let engine = AVAudioEngine()
            os_log(.info, log: recordingLog, "AVAudioEngine created: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            // Set specific input device if requested
            if let uid = deviceUID, !uid.isEmpty, uid != "default",
               let deviceID = AudioDevice.deviceID(forUID: uid) {
                os_log(.info, log: recordingLog, "device lookup resolved to %d: %.3fms", deviceID, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
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
            }

            let inputNode = engine.inputNode
            os_log(.info, log: recordingLog, "inputNode accessed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let inputFormat = inputNode.outputFormat(forBus: 0)
            os_log(.info, log: recordingLog, "inputFormat retrieved (rate=%.0f, ch=%d): %.3fms", inputFormat.sampleRate, inputFormat.channelCount, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard inputFormat.sampleRate > 0 else {
                throw AudioRecorderError.invalidInputFormat("Invalid sample rate: \(inputFormat.sampleRate)")
            }
            guard inputFormat.channelCount > 0 else {
                throw AudioRecorderError.invalidInputFormat("No input channels available")
            }

            storedInputFormat = inputFormat

            // Install tap — converts to 16kHz mono in real-time during recording
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self, self._recording.withLock({ $0 }) else { return }

                self.bufferCount += 1

                // Check if this buffer has real audio
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
            os_log(.info, log: recordingLog, "tap installed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            engine.prepare()
            os_log(.info, log: recordingLog, "engine prepared: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            self.audioEngine = engine
            self.currentDeviceUID = deviceUID
        }

        // Start engine if not already running
        if let engine = audioEngine, !engine.isRunning {
            try engine.start()
            os_log(.info, log: recordingLog, "engine started: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        guard let inputFormat = storedInputFormat else {
            throw AudioRecorderError.invalidInputFormat("No stored input format")
        }

        // Create a temp file — write directly in 16kHz mono (no post-recording conversion needed)
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
        os_log(.info, log: recordingLog, "audio file created (16kHz mono, realtime conversion): %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        audioFileQueue.sync { self.audioFile = newAudioFile }
        _recording.withLock { $0 = true }
        self.isRecording = true
        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func stopRecording() -> URL? {
        let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received", elapsed, bufferCount)

        _recording.withLock { $0 = false }
        audioFileQueue.sync { audioFile = nil }
        isRecording = false
        smoothedLevel = 0.0
        DispatchQueue.main.async { self.audioLevel = 0.0 }

        // Stop engine so mic indicator goes away — keep engine object for fast restart
        audioEngine?.stop()
        realtimeConverter = nil
        os_log(.info, log: recordingLog, "engine stopped (mic indicator off)")

        // Debug: check the recorded file
        if let url = tempFileURL {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let fileSize = attrs[.size] as? UInt64 ?? 0
                    os_log(.info, log: recordingLog, "recorded file: %{public}@, size=%llu bytes", url.lastPathComponent, fileSize)
                    if fileSize == 0 {
                        os_log(.error, log: recordingLog, "WARNING: recorded file is EMPTY (0 bytes)!")
                    }
                } catch {
                    os_log(.error, log: recordingLog, "failed to get file attributes: %{public}@", error.localizedDescription)
                }
            } else {
                os_log(.error, log: recordingLog, "ERROR: temp file does not exist at %{public}@", url.path)
            }
        } else {
            os_log(.error, log: recordingLog, "ERROR: tempFileURL is nil")
        }

        return tempFileURL
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

        // Scale RMS (~0.01-0.1 for speech) to 0-1 range
        let scaled = min(rms * 10.0, 1.0)

        // Fast attack, slower release — follows speech dynamics closely
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
