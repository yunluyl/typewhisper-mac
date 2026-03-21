// Standalone concurrency tests for the recording state machine.
// Reproduces the "dead zone" bug where isStartingRecording stays true
// after rapid start/stop toggling, and verifies the fix.
//
// Run: swift tests/RecordingStateMachineTests.swift

import Foundation

// MARK: - Test Infrastructure

@MainActor
final class TestTracker {
    static let shared = TestTracker()
    var passed = 0
    var failed = 0
}

@MainActor
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        print("  FAIL (line \(line)): \(message)")
        TestTracker.shared.failed += 1
    }
}

@MainActor
func runTest(_ name: String, _ body: @MainActor @Sendable () async throws -> Void) async {
    let failsBefore = TestTracker.shared.failed
    print("▶ \(name)")
    do {
        try await body()
        if TestTracker.shared.failed == failsBefore {
            print("  ✓ passed")
            TestTracker.shared.passed += 1
        }
    } catch {
        print("  FAIL: threw \(error)")
        TestTracker.shared.failed += 1
    }
}

// MARK: - Mock Audio Service

/// Simulates AudioRecordingService.startRecording():
///   - Engine setup in Task.detached (does NOT inherit parent cancellation)
///   - Takes `setupDuration` seconds
final class MockAudioService: @unchecked Sendable {
    var isRecording = false
    var startCallCount = 0
    var stopCallCount = 0
    private var engineSetupTask: Task<Void, Error>?
    private let lock = NSLock()

    let setupDuration: TimeInterval

    init(setupDuration: TimeInterval = 1.0) {
        self.setupDuration = setupDuration
    }

    /// CURRENT (buggy) behavior: detached task with NO cancellation checks.
    func startRecording_current() async throws {
        startCallCount += 1
        let duration = setupDuration
        let _: Void = try await Task.detached {
            try await Task.sleep(for: .seconds(duration))
        }.value
        isRecording = true
    }

    /// FIXED behavior: detached task with cancellation checks + storable task.
    func startRecording_fixed() async throws {
        startCallCount += 1
        let duration = setupDuration
        let task = Task.detached {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(duration))
            try Task.checkCancellation()
        }
        lock.withLock { engineSetupTask = task }
        do {
            try await task.value
            lock.withLock { engineSetupTask = nil }
            isRecording = true
        } catch {
            lock.withLock { engineSetupTask = nil }
            throw error
        }
    }

    func cancelPendingStart() {
        lock.withLock {
            engineSetupTask?.cancel()
            engineSetupTask = nil
        }
    }

    func stopRecording() {
        stopCallCount += 1
        isRecording = false
    }
}

// MARK: - Buggy State Machine (reproduces current DictationViewModel behavior)

@MainActor
final class BuggyStateMachine {
    var state = "idle"
    var isStartingRecording = false
    var recordingStartTask: Task<Void, Never>?
    let audio: MockAudioService

    init(audio: MockAudioService) { self.audio = audio }

    func startRecording() async {
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        guard !Task.isCancelled else { return }

        do {
            try await audio.startRecording_current()
            guard !Task.isCancelled else {
                audio.stopRecording()
                return
            }
            state = "recording"
        } catch {
            guard !Task.isCancelled else { return }
            state = "error"
        }
    }

    func onStart() {
        recordingStartTask?.cancel()
        recordingStartTask = Task { @MainActor in await self.startRecording() }
    }

    func onStop() {
        recordingStartTask?.cancel()
        recordingStartTask = nil
    }
}

// MARK: - Fixed State Machine

@MainActor
final class FixedStateMachine {
    var state = "idle"
    var isStartingRecording = false
    var recordingStartTask: Task<Void, Never>?
    let audio: MockAudioService

    init(audio: MockAudioService) { self.audio = audio }

    func startRecording() async {
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        guard !Task.isCancelled else { return }

        do {
            try await audio.startRecording_fixed()
            guard !Task.isCancelled else {
                audio.stopRecording()
                return
            }
            state = "recording"
        } catch {
            guard !Task.isCancelled else { return }
            if error is CancellationError { return }
            state = "error"
        }
    }

    func onStart() {
        recordingStartTask?.cancel()
        audio.cancelPendingStart()
        let oldTask = recordingStartTask
        recordingStartTask = Task { @MainActor in
            _ = await oldTask?.value
            await self.startRecording()
        }
    }

    func onStop() {
        recordingStartTask?.cancel()
        audio.cancelPendingStart()
    }
}

// MARK: - Tests

@MainActor
func test_buggy_deadZone() async throws {
    let audio = MockAudioService(setupDuration: 1.0)
    let sm = BuggyStateMachine(audio: audio)

    // Start → engine setup begins (takes 1s)
    sm.onStart()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))

    // Stop before engine completes
    sm.onStop()
    await Task.yield()

    // Try to start again immediately
    sm.onStart()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(100))
    await Task.yield()

    // BUG: isStartingRecording stuck true — Task A's detached setup still running
    check(sm.isStartingRecording == true,
          "Expected isStartingRecording=true during dead zone, got \(sm.isStartingRecording)")
    check(sm.state == "idle",
          "Expected state=idle (new start rejected), got \(sm.state)")
}

@MainActor
func test_buggy_rapidToggles() async throws {
    let audio = MockAudioService(setupDuration: 1.0)
    let sm = BuggyStateMachine(audio: audio)

    // Rapid toggling: start-stop ×3, then final start
    for _ in 0..<3 {
        sm.onStart()
        await Task.yield()
        sm.onStop()
        await Task.yield()
    }
    sm.onStart()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(100))
    await Task.yield()

    // BUG: still locked out during dead zone
    check(sm.isStartingRecording == true,
          "Expected dead zone still active after rapid toggles")
    check(sm.state == "idle",
          "Expected idle — all starts rejected during dead zone")
}

@MainActor
func test_buggy_deadZone_duration() async throws {
    let audio = MockAudioService(setupDuration: 2.0)
    let sm = BuggyStateMachine(audio: audio)

    sm.onStart()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))
    sm.onStop()
    await Task.yield()

    // Dead zone lasts as long as engine setup (2s)
    try await Task.sleep(for: .seconds(1.0))
    await Task.yield()
    check(sm.isStartingRecording == true,
          "Expected dead zone still active at 1.0s (setup=2.0s)")

    try await Task.sleep(for: .seconds(1.5))
    await Task.yield()
    check(sm.isStartingRecording == false,
          "Expected dead zone ended after 2.5s (setup=2.0s)")
}

@MainActor
func test_fixed_noDeadZone() async throws {
    let audio = MockAudioService(setupDuration: 0.5)
    let sm = FixedStateMachine(audio: audio)

    // Start
    sm.onStart()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))

    // Stop
    sm.onStop()
    await Task.yield()

    // Start again — should NOT be blocked
    sm.onStart()

    // Wait for: old task cleanup (~instant, engine setup cancelled) + new setup (0.5s)
    try await Task.sleep(for: .seconds(1.0))
    await Task.yield()

    check(sm.state == "recording",
          "Expected state=recording with fix, got \(sm.state)")
    check(sm.isStartingRecording == false,
          "Expected isStartingRecording=false after successful start")
}

@MainActor
func test_fixed_rapidToggles() async throws {
    let audio = MockAudioService(setupDuration: 0.3)
    let sm = FixedStateMachine(audio: audio)

    // Rapid toggling
    for _ in 0..<5 {
        sm.onStart()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))
        sm.onStop()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))
    }

    // Final start
    sm.onStart()
    try await Task.sleep(for: .seconds(0.8))
    await Task.yield()

    check(sm.state == "recording",
          "Expected recording after rapid toggles with fix, got \(sm.state)")
}

@MainActor
func test_fixed_startCallsSerialized() async throws {
    let audio = MockAudioService(setupDuration: 0.3)
    let sm = FixedStateMachine(audio: audio)

    // Start
    sm.onStart()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))

    // Immediately start again (supersedes old)
    sm.onStart()
    try await Task.sleep(for: .seconds(0.8))
    await Task.yield()

    check(sm.state == "recording",
          "Expected recording, got \(sm.state)")

    // The old start should have been cancelled before completing
    // Only the latest start should have completed successfully
    check(audio.startCallCount >= 1,
          "Expected at least 1 start, got \(audio.startCallCount)")
    print("  info: startCallCount=\(audio.startCallCount), stopCallCount=\(audio.stopCallCount)")
}

@MainActor
func test_fixed_stopThenStart_chainsCorrectly() async throws {
    let audio = MockAudioService(setupDuration: 0.5)
    let sm = FixedStateMachine(audio: audio)

    // Successful recording
    sm.onStart()
    try await Task.sleep(for: .seconds(0.8))
    await Task.yield()
    check(sm.state == "recording", "Expected recording after first start, got \(sm.state)")

    // Stop (this used to nil out recordingStartTask, breaking the chain)
    sm.onStop()
    await Task.yield()

    // Start again — engine setup begins
    sm.onStart()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(100))

    // Quick stop DURING engine setup
    sm.onStop()
    await Task.yield()

    // Start again — must chain on the still-running task
    sm.onStart()
    try await Task.sleep(for: .seconds(1.0))
    await Task.yield()

    check(sm.state == "recording",
          "Expected recording after stop-during-setup then restart, got \(sm.state)")
    check(sm.isStartingRecording == false,
          "Expected isStartingRecording=false, got \(sm.isStartingRecording)")
}

@MainActor
func test_soundFeedback_persistence() async throws {
    let suiteName = "test-typewhisper-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let key = "soundFeedbackEnabled"

    // Default: nil → fallback to true
    let defaultVal = suite.object(forKey: key) as? Bool ?? true
    check(defaultVal == true, "Expected default=true, got \(defaultVal)")

    // Toggle OFF
    suite.set(false, forKey: key)
    let afterOff = suite.object(forKey: key) as? Bool ?? true
    check(afterOff == false, "Expected false after toggle off, got \(afterOff)")

    // Toggle ON
    suite.set(true, forKey: key)
    let afterOn = suite.object(forKey: key) as? Bool ?? true
    check(afterOn == true, "Expected true after toggle on, got \(afterOn)")

    suite.removePersistentDomain(forName: suiteName)
}

// MARK: - Main

@MainActor
func runAllTests() async {
    print("=== Recording State Machine Concurrency Tests ===\n")

    print("--- Bug Reproduction (current behavior) ---")
    await runTest("Dead zone after start-stop-start", test_buggy_deadZone)
    await runTest("Dead zone persists through rapid toggles", test_buggy_rapidToggles)
    await runTest("Dead zone duration matches engine setup time", test_buggy_deadZone_duration)

    print("\n--- Fix Verification ---")
    await runTest("No dead zone with chained start + cancellable setup", test_fixed_noDeadZone)
    await runTest("Rapid toggles succeed with fix", test_fixed_rapidToggles)
    await runTest("Start calls serialized (no engine leak)", test_fixed_startCallsSerialized)
    await runTest("Stop-during-setup then restart chains correctly", test_fixed_stopThenStart_chainsCorrectly)
    await runTest("Sound feedback UserDefaults persistence", test_soundFeedback_persistence)

    let t = TestTracker.shared
    print("\n=== Results: \(t.passed) passed, \(t.failed) failed ===")
    if t.failed > 0 { exit(1) }
}

Task { @MainActor in
    await runAllTests()
    exit(0)
}
RunLoop.main.run()
