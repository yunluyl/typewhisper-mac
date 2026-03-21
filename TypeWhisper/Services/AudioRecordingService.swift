import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import AppKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecordingService")

private struct Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Captures microphone audio via AVAudioEngine and converts to 16kHz mono Float32 samples.
final class AudioRecordingService: ObservableObject, @unchecked Sendable {

    enum AudioRecordingError: LocalizedError {
        case microphonePermissionDenied
        case engineStartFailed(String)
        case noAudioData

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone permission denied. Please grant access in System Settings."
            case .engineStartFailed(let detail):
                "Failed to start audio engine: \(detail)"
            case .noAudioData:
                "No audio data was recorded."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var rawAudioLevel: Float = 0

    /// Called on the main actor when the engine fails to restart after a configuration change.
    /// The sample buffer still holds all audio captured before the failure.
    /// Always set and called from the main actor; no annotation to avoid init-isolation conflict.
    nonisolated(unsafe) var onRecordingFailed: (() -> Void)?

    /// CoreAudio device ID to use for recording. nil = system default input.
    var selectedDeviceID: AudioDeviceID? {
        get { configLock.withLock { _selectedDeviceID } }
        set { configLock.withLock { _selectedDeviceID = newValue } }
    }

    private var _selectedDeviceID: AudioDeviceID?

    private var audioEngine: AVAudioEngine?
    private var configChangeObserver: NSObjectProtocol?
    private var lastConfigChangeRestart: Date = .distantPast
    private var sampleBuffer: [Float] = []
    private var _peakRawAudioLevel: Float = 0
    private let bufferLock = NSLock()
    private let configLock = NSLock()
    private let engineSetupHolder = OSAllocatedUnfairLock<Task<AVAudioEngine, Error>?>(initialState: nil)
    private let retiredEngineHolder = OSAllocatedUnfairLock<AVAudioEngine?>(initialState: nil)
    private let processingQueue = DispatchQueue(label: "com.typewhisper.audio-processing", qos: .userInteractive)

    static let targetSampleRate: Double = 16000

    static func getDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    var peakRawAudioLevel: Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _peakRawAudioLevel
    }

    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func requestMicrophonePermission() async -> Bool {
        let permission = AVAudioApplication.shared.recordPermission
        if permission == .granted { return true }
        if permission == .undetermined {
            // Request permission via the official AVAudioApplication API
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        // .denied — open System Settings so user can grant manually
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        return false
    }

    /// Cancels any in-progress engine setup from a previous startRecording() call.
    /// Safe to call from any thread. The cancelled setup task will throw CancellationError,
    /// causing startRecording() to throw promptly instead of blocking for 2-3 seconds.
    func cancelPendingStart() {
        let task = engineSetupHolder.withLock { holder in
            let t = holder
            holder = nil
            return t
        }
        task?.cancel()
    }

    /// Thread-safe snapshot of the current recording buffer for streaming transcription.
    func getCurrentBuffer() -> [Float] {
        bufferLock.lock()
        let copy = sampleBuffer
        bufferLock.unlock()
        return copy
    }

    /// Returns at most the last `maxDuration` seconds of audio for streaming.
    func getRecentBuffer(maxDuration: TimeInterval) -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let maxSamples = Int(maxDuration * Self.targetSampleRate)
        if sampleBuffer.count <= maxSamples { return sampleBuffer }
        return Array(sampleBuffer.suffix(maxSamples))
    }

    /// Total duration of the recorded audio in seconds.
    var totalBufferDuration: TimeInterval {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return Double(sampleBuffer.count) / Self.targetSampleRate
    }

    func startRecording() async throws {
        guard hasMicrophonePermission else {
            throw AudioRecordingError.microphonePermissionDenied
        }

        let deviceID = selectedDeviceID ?? Self.getDefaultInputDeviceID()

        bufferLock.withLock {
            sampleBuffer.removeAll()
            _peakRawAudioLevel = 0
        }

        // Run AVAudioEngine setup off the main thread to avoid deadlocking
        // with AVAudioNode's internal dispatch_sync in outputFormat(forBus:).
        let weak_self = Weak(self)
        let setupTask = Task.detached(priority: .userInitiated) {
            let engine = AVAudioEngine()

            try Task.checkCancellation()

            if let deviceID, let audioUnit = engine.inputNode.audioUnit {
                var id = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            try Task.checkCancellation()

            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw AudioRecordingError.engineStartFailed("No audio input available")
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioRecordingService.targetSampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw AudioRecordingError.engineStartFailed("Cannot create target audio format")
            }

            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            guard let converter else {
                throw AudioRecordingError.engineStartFailed("Cannot create audio converter")
            }

            try Task.checkCancellation()

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                weak_self.value?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
            }

            do {
                try engine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                throw AudioRecordingError.engineStartFailed(error.localizedDescription)
            }

            guard !Task.isCancelled else {
                inputNode.removeTap(onBus: 0)
                engine.stop()
                // Park the stopped engine to prevent immediate dealloc racing with
                // CoreAudio callbacks. It gets replaced on next cancellation or start.
                weak_self.value?.retiredEngineHolder.withLock { $0 = engine }
                throw CancellationError()
            }

            return engine
        }

        engineSetupHolder.withLock { $0 = setupTask }

        let engine: AVAudioEngine
        do {
            engine = try await setupTask.value
        } catch {
            engineSetupHolder.withLock { $0 = nil }
            throw error
        }

        engineSetupHolder.withLock { $0 = nil }

        audioEngine = engine
        isRecording = true
        lastConfigChangeRestart = Date()

        let weakSelf = Weak(self)
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            Task.detached(priority: .userInitiated) {
                await weakSelf.value?.handleConfigurationChange()
            }
        }
    }

    func stopRecording() -> [Float] {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        // Keep audioEngine alive — immediate dealloc races with CoreAudio's internal
        // dispatch queues (AVAudioIOUnit, AggregateDevice). The old engine is safely
        // released when the next startRecording() replaces it.

        // Flush pending audio processing before grabbing the buffer
        processingQueue.sync { }

        bufferLock.lock()
        let samples = sampleBuffer
        sampleBuffer.removeAll()
        bufferLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.audioLevel = 0
        }

        return samples
    }

    /// Re-setup the audio engine after a system configuration change (e.g. notification sound).
    /// Preserves already-buffered samples so no audio is lost.
    @MainActor
    private func handleConfigurationChange() {
        guard isRecording, let engine = audioEngine else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastConfigChangeRestart)
        guard elapsed > 2.0 else {
            logger.info("Audio engine config change ignored — last restart was \(String(format: "%.1f", elapsed))s ago (debounce 2s)")
            return
        }
        lastConfigChangeRestart = now
        logger.warning("Audio engine configuration changed during recording, restarting engine")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let deviceID = selectedDeviceID ?? Self.getDefaultInputDeviceID()
        let weakSelf = Weak(self)

        Task.detached(priority: .userInitiated) {
            if let deviceID, let audioUnit = engine.inputNode.audioUnit {
                var id = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                logger.error("Cannot restart engine: no audio input available")
                await MainActor.run { weakSelf.value?.onRecordingFailed?() }
                return
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioRecordingService.targetSampleRate,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                logger.error("Cannot restart engine: failed to create format/converter")
                await MainActor.run { weakSelf.value?.onRecordingFailed?() }
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                weakSelf.value?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
            }

            do {
                try engine.start()
                logger.info("Audio engine restarted successfully")
            } catch {
                inputNode.removeTap(onBus: 0)
                logger.error("Failed to restart audio engine: \(error.localizedDescription)")
                await MainActor.run { weakSelf.value?.onRecordingFailed?() }
            }
        }
    }

    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Convert sample rate on the render thread (AVAudioConverter requires thread consistency)
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * Self.targetSampleRate / buffer.format.sampleRate
        )
        guard frameCount > 0 else { return }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCount
        ) else { return }

        var error: NSError?
        let consumed = OSAllocatedUnfairLock(initialState: false)

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            let wasConsumed = consumed.withLock { flag in
                let prev = flag
                flag = true
                return prev
            }
            if wasConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, convertedBuffer.frameLength > 0 else { return }
        guard let channelData = convertedBuffer.floatChannelData?[0] else { return }

        // Quick copy of converted samples, then dispatch heavy work off the render thread
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))

        processingQueue.async { [weak self] in
            self?.processConvertedSamples(samples)
        }
    }

    private func processConvertedSamples(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let normalizedLevel = min(1.0, rms * 5) // Scale up for visibility

        bufferLock.lock()
        sampleBuffer.append(contentsOf: samples)
        if rms > _peakRawAudioLevel { _peakRawAudioLevel = rms }
        bufferLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioLevel = normalizedLevel
            self.rawAudioLevel = rms
        }
    }
}
