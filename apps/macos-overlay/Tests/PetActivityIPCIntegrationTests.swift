import AppKit
import Foundation

@main
struct PetActivityIPCIntegrationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/tmp/pet-activity-(UUID().uuidString.prefix(8))")
        let previousHome = getenv("CODEX_HOME").map { String(cString: $0) }
        setenv("CODEX_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) }
            else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: root)
        }

        let suite = "pet-activity-(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OverlayState(readDefaults: defaults)
        let socketPath = root.appendingPathComponent("codex-flow/overlay.sock").path
        let server = IPCService.Server(state: state, socketPath: socketPath)
        defer { server.stop() }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let started = event("started", sequence: 1, timestamp: now)
        let running = event("running", sequence: 2, timestamp: now + 1)
        let waiting = event("waiting", sequence: 3, timestamp: now + 2)
        let succeeded = event("succeeded", sequence: 4, timestamp: now + 3)
        let completed = event("completed", sequence: 5, timestamp: now + 4)
        let lateRunning = event("running", sequence: 6, timestamp: now + 5)

        let startResponse = send(started, socketPath: socketPath)
        precondition(startResponse.contains("\"ok\":true") && state.petAnimator.state == .running)
        let runningResponse = send(running, socketPath: socketPath)
        precondition(runningResponse.contains("\"accepted\":true") && state.petAnimator.state == .running)
        let waitingResponse = send(waiting, socketPath: socketPath)
        precondition(waitingResponse.contains("\"accepted\":true") && state.petAnimator.state == .waiting)
        let successResponse = send(succeeded, socketPath: socketPath)
        precondition(successResponse.contains("\"accepted\":true") && state.petAnimator.state == .jumping)
        let completionResponse = send(completed, socketPath: socketPath)
        precondition(completionResponse.contains("\"accepted\":true") && state.petAnimator.state == .jumping,
                     "Stop completion must not celebrate a successful turn twice")
        let rejectedResponse = send(lateRunning, socketPath: socketPath)
        precondition(rejectedResponse.contains("\"ok\":false") && state.petAnimator.state == .jumping,
                     "Late tool activity must not revive a terminal turn")

        let nextStarted = event("started", session: "next-session", turn: "next-turn", sequence: 1, timestamp: now + 6)
        _ = send(nextStarted, socketPath: socketPath)
        precondition(state.petAnimator.state == .running)
        let expired = state.petActivityConsumer.expire(nowMilliseconds: now + 6 + PetActivityTracker.activityTTLMilliseconds + 1)
        precondition(expired.unavailable && expired.clear && state.petAnimator.state == .idle,
                     "Expired activity must become idle and unavailable")

        let failedPayload = event("failed", session: "failed-session", turn: "failed-turn", sequence: 1, timestamp: now)
            .replacingOccurrences(of: "pet event ", with: "")
        let activitySnapshot = root.appendingPathComponent("codex-flow/telemetry/activity/state.json")
        try FileManager.default.createDirectory(at: activitySnapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(failedPayload.utf8).write(to: activitySnapshot)
        let recoveredDefaults = UserDefaults(suiteName: "(suite)-recovered")!
        defer { recoveredDefaults.removePersistentDomain(forName: "(suite)-recovered") }
        let recovered = OverlayState(readDefaults: recoveredDefaults)
        precondition(recovered.petAnimator.state == .failed && !recovered.petActivityUnavailable,
                     "Explicit failed activity must survive overlay recovery")

        print("Pet activity reducer and native IPC consumer tests passed")
    }

    private static func event(
        _ name: String,
        session: String = "ipc-session",
        turn: String = "ipc-turn",
        sequence: Int,
        timestamp: Int64
    ) -> String {
        let value: [String: Any] = [
            "schema_version": 1,
            "event": name,
            "session_id": session,
            "turn_id": turn,
            "sequence": sequence,
            "timestamp_ms": timestamp,
            "started_at_ms": timestamp - Int64(sequence - 1),
            "source": "test",
        ]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return "pet event " + String(data: data, encoding: .utf8)!
    }

    private static func send(_ command: String, socketPath: String) -> String {
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = IPCService.sendCommand(command + "\n", socketPath: socketPath).response
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value ?? ""
    }

    private final class ResponseBox: NSObject {
        var value: String?
    }
}
