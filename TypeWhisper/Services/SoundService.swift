import AppKit
import os

enum SoundEvent: CustomStringConvertible {
    case recordingStarted
    case transcriptionSuccess
    case error

    var fileName: String {
        switch self {
        case .recordingStarted: return "recording_start"
        case .transcriptionSuccess: return "transcription_success"
        case .error: return "error"
        }
    }

    var description: String {
        switch self {
        case .recordingStarted: return "recordingStarted"
        case .transcriptionSuccess: return "transcriptionSuccess"
        case .error: return "error"
        }
    }
}

@MainActor
class SoundService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "SoundService")
    private var sounds: [SoundEvent: NSSound] = [:]

    init() {
        preloadSounds()
    }

    func play(_ event: SoundEvent, enabled: Bool) {
        guard enabled else { return }
        if let sound = sounds[event] {
            sound.stop()
            sound.play()
        } else {
            logger.warning("play(\(event.description)): no preloaded sound found")
        }
    }

    private func preloadSounds() {
        for event in [SoundEvent.recordingStarted, .transcriptionSuccess, .error] {
            if let url = Bundle.main.url(forResource: event.fileName, withExtension: "wav") {
                sounds[event] = NSSound(contentsOf: url, byReference: true)
            } else {
                logger.warning("preload: missing sound file for \(event.description) (\(event.fileName).wav)")
            }
        }
    }
}
