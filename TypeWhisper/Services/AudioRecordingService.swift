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
    private var deferredRestartTask: Task<Void, Never>?
    private var sampleBuffer: [Float] = []
    private var _peakRawAudioLevel: Float = 0
    private let bufferLock = NSLock()
    private let configLock = NSLock()
    private let engineSetupHolder = OSAllocatedUnfairLock<Task<AVAudioEngine, Error>?>(initialState: nil)
    private let retiredEngineHolder = OSAllocatedUnfairLock<AVAudioEngine?>(initialState: nil)
    private let processingQueue = DispatchQueue(label: "com.typewhisper.audio-processing", qos: .userInteractive)

    static let targetSampleRate: Double = 16000
    private var tapCallbackCount: Int = 0
    private var lastDiagLogTime: Date = .distantPast

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

    static func deviceName(for deviceID: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cf = name else { return "unknown(\(deviceID))" }
        return cf.takeUnretainedValue() as String
    }

    static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer)
        guard getStatus == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var channels = 0
        for buffer in bufferList { channels += Int(buffer.mNumberChannels) }
        return channels
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

        var deviceID = selectedDeviceID
        var isBluetooth = false
        if let did = deviceID {
            let channels = Self.inputChannelCount(for: did)
            isBluetooth = Self.isBluetoothDevice(did)
            logger.warning("[DIAG] startRecording: selectedDeviceID=\(did), name='\(Self.deviceName(for: did), privacy: .public)', inputChannels=\(channels), bluetooth=\(isBluetooth)")
            if channels == 0 {
                logger.warning("[DIAG] Selected device has no input channels, falling back to engine default")
                deviceID = nil
            } else if isBluetooth {
                logger.warning("[DIAG] Bluetooth device — skipping explicit AudioUnit set, using engine aggregate routing")
                deviceID = nil
            }
        } else {
            logger.warning("[DIAG] startRecording: no selectedDeviceID, using engine default")
        }

        bufferLock.withLock {
            sampleBuffer.removeAll()
            _peakRawAudioLevel = 0
        }
        tapCallbackCount = 0

        // Run AVAudioEngine setup off the main thread to avoid deadlocking
        // with AVAudioNode's internal dispatch_sync in outputFormat(forBus:).
        let weak_self = Weak(self)
        let setupTask = Task.detached(priority: .userInitiated) {
            let engine = AVAudioEngine()

            try Task.checkCancellation()

            if let deviceID, let audioUnit = engine.inputNode.audioUnit {
                var id = deviceID
                let setStatus = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                logger.warning("[DIAG] AudioUnitSetProperty(CurrentDevice=\(deviceID)): status=\(setStatus) (0=ok)")
            } else {
                logger.warning("[DIAG] Skipped device set: deviceID=\(deviceID.map { String($0) } ?? "nil"), audioUnit=\(engine.inputNode.audioUnit.map { String(describing: $0) } ?? "nil")")
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            try Task.checkCancellation()

            logger.warning("[DIAG] inputFormat: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount), bitsPerChannel=\(inputFormat.streamDescription.pointee.mBitsPerChannel), formatFlags=\(inputFormat.streamDescription.pointee.mFormatFlags)")

            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                logger.warning("[DIAG] FAILED: input format invalid — no audio input available")
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
                logger.warning("[DIAG] FAILED: cannot create converter from \(inputFormat) to \(targetFormat)")
                throw AudioRecordingError.engineStartFailed("Cannot create audio converter")
            }

            logger.warning("[DIAG] Converter created: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch → \(targetFormat.sampleRate)Hz \(targetFormat.channelCount)ch")

            try Task.checkCancellation()

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                weak_self.value?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
            }
            logger.warning("[DIAG] Tap installed on bus 0, bufferSize=4096")

            do {
                try engine.start()
                logger.warning("[DIAG] Engine started. isRunning=\(engine.isRunning)")
            } catch {
                inputNode.removeTap(onBus: 0)
                logger.warning("[DIAG] Engine start FAILED: \(error.localizedDescription)")
                throw AudioRecordingError.engineStartFailed(error.localizedDescription)
            }

            guard !Task.isCancelled else {
                inputNode.removeTap(onBus: 0)
                engine.stop()
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
            logger.warning("[DIAG] startRecording threw: \(error.localizedDescription)")
            throw error
        }

        engineSetupHolder.withLock { $0 = nil }

        audioEngine = engine
        isRecording = true
        lastConfigChangeRestart = .distantPast // allow immediate restart if engine dies during setup
        logger.warning("[DIAG] Recording active. engine.isRunning=\(engine.isRunning)")

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

        // The Bluetooth aggregate device may still be stabilizing after engine.start().
        // Config changes that fired between start() and observer registration are lost.
        // If the engine already died, trigger an immediate restart.
        if !engine.isRunning {
            logger.warning("[DIAG] Engine died during observer registration gap, restarting immediately")
            await MainActor.run { [weak self] in self?.handleConfigurationChange() }
        }
    }

    func stopRecording() -> [Float] {
        let engineWasRunning = audioEngine?.isRunning ?? false
        logger.warning("[DIAG] stopRecording: tapCallbacks=\(self.tapCallbackCount), engine.isRunning=\(engineWasRunning)")

        deferredRestartTask?.cancel()
        deferredRestartTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // Flush pending audio processing before grabbing the buffer
        processingQueue.sync { }

        bufferLock.lock()
        let samples = sampleBuffer
        let peak = _peakRawAudioLevel
        sampleBuffer.removeAll()
        bufferLock.unlock()

        logger.warning("[DIAG] stopRecording: samples=\(samples.count), duration=\(String(format: "%.2f", Double(samples.count) / Self.targetSampleRate))s, peakRMS=\(peak)")

        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.audioLevel = 0
        }

        return samples
    }

    /// Re-setup the audio engine after a system configuration change (e.g. notification sound).
    /// Creates a fresh AVAudioEngine to avoid stale state (e.g. after Bluetooth profile switch).
    /// Preserves already-buffered samples so no audio is lost.
    @MainActor
    private func handleConfigurationChange() {
        guard isRecording, let oldEngine = audioEngine else { return }

        deferredRestartTask?.cancel()
        deferredRestartTask = nil

        let now = Date()
        let elapsed = now.timeIntervalSince(lastConfigChangeRestart)
        guard elapsed > 2.0 else {
            let delay = 2.0 - elapsed + 0.1
            logger.info("Audio engine config change deferred by \(String(format: "%.1f", delay))s (last restart \(String(format: "%.1f", elapsed))s ago)")
            deferredRestartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.handleConfigurationChange()
            }
            return
        }
        lastConfigChangeRestart = now
        logger.warning("Audio engine configuration changed during recording, restarting with fresh engine")

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()

        var deviceID = selectedDeviceID
        if let did = deviceID {
            if Self.inputChannelCount(for: did) == 0 {
                logger.warning("[DIAG] configChange: selected device \(did) has no input channels, using engine default")
                deviceID = nil
            } else if Self.isBluetoothDevice(did) {
                deviceID = nil
            }
        }
        let weakSelf = Weak(self)

        let setupTask = Task.detached(priority: .userInitiated) { () -> AVAudioEngine? in
            let engine = AVAudioEngine()

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
                logger.error("Cannot restart engine: no audio input available (format: \(inputFormat))")
                return nil
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioRecordingService.targetSampleRate,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                logger.error("Cannot restart engine: failed to create format/converter")
                return nil
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                weakSelf.value?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
            }

            do {
                try engine.start()
                logger.warning("[DIAG] Engine restarted successfully after config change. isRunning=\(engine.isRunning)")
            } catch {
                inputNode.removeTap(onBus: 0)
                logger.error("Failed to restart audio engine: \(error.localizedDescription)")
                return nil
            }

            return engine
        }

        Task { @MainActor [weak self] in
            guard let newEngine = await setupTask.value else {
                self?.onRecordingFailed?()
                return
            }
            guard let self, self.isRecording else {
                newEngine.inputNode.removeTap(onBus: 0)
                newEngine.stop()
                return
            }
            self.audioEngine = newEngine
            self.configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: newEngine,
                queue: nil
            ) { _ in
                Task.detached(priority: .userInitiated) {
                    await weakSelf.value?.handleConfigurationChange()
                }
            }
        }
    }

    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        tapCallbackCount += 1

        if tapCallbackCount == 1 {
            logger.warning("[DIAG] First tap callback! buffer.frameLength=\(buffer.frameLength), format.sampleRate=\(buffer.format.sampleRate), channels=\(buffer.format.channelCount)")
        }

        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * Self.targetSampleRate / buffer.format.sampleRate
        )
        guard frameCount > 0 else {
            if tapCallbackCount <= 3 {
                logger.warning("[DIAG] tap callback #\(self.tapCallbackCount): frameCount=0, skipping")
            }
            return
        }

        // Log raw input RMS on first few buffers
        if tapCallbackCount <= 5, let rawData = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += rawData[i] * rawData[i] }
            let rawRms = sqrt(sum / Float(buffer.frameLength))
            logger.warning("[DIAG] tap callback #\(self.tapCallbackCount): raw input RMS=\(rawRms), frames=\(buffer.frameLength)")
        }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCount
        ) else {
            if tapCallbackCount <= 3 {
                logger.warning("[DIAG] tap callback #\(self.tapCallbackCount): failed to create convertedBuffer")
            }
            return
        }

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

        if let error {
            if tapCallbackCount <= 5 {
                logger.warning("[DIAG] tap callback #\(self.tapCallbackCount): converter error=\(error.localizedDescription)")
            }
            return
        }

        guard convertedBuffer.frameLength > 0 else {
            if tapCallbackCount <= 3 {
                logger.warning("[DIAG] tap callback #\(self.tapCallbackCount): convertedBuffer.frameLength=0")
            }
            return
        }
        guard let channelData = convertedBuffer.floatChannelData?[0] else {
            if tapCallbackCount <= 3 {
                logger.warning("[DIAG] tap callback #\(self.tapCallbackCount): no channelData")
            }
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))

        processingQueue.async { [weak self] in
            self?.processConvertedSamples(samples)
        }
    }

    private func processConvertedSamples(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let normalizedLevel = min(1.0, rms * 5)

        bufferLock.lock()
        sampleBuffer.append(contentsOf: samples)
        let totalSamples = sampleBuffer.count
        if rms > _peakRawAudioLevel { _peakRawAudioLevel = rms }
        let peakSoFar = _peakRawAudioLevel
        bufferLock.unlock()

        // Periodic diagnostic: log every ~2 seconds
        let now = Date()
        if now.timeIntervalSince(lastDiagLogTime) >= 2.0 {
            lastDiagLogTime = now
            logger.warning("[DIAG] recording stats: tapCallbacks=\(self.tapCallbackCount), bufferSamples=\(totalSamples), duration=\(String(format: "%.1f", Double(totalSamples) / Self.targetSampleRate))s, currentRMS=\(rms), peakRMS=\(peakSoFar)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioLevel = normalizedLevel
            self.rawAudioLevel = rms
        }
    }
}
