import AppKit
import Foundation

@main
struct OverlayStateStartupTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-startup-\(UUID().uuidString)")
        let previousHome = getenv("CODEX_HOME").map { String(cString: $0) }
        setenv("CODEX_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) }
            else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        let directory = root.appendingPathComponent("codex-flow/telemetry")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = TaskRun(sessionId: "startup", turnId: "stale", finishedAtMs: 1,
                            publication: PublicationInfo(revision: 1, completedAtMs: 1))
        try JSONEncoder().encode(stale).write(to: directory.appendingPathComponent("last.json"))
        let suite = "flowpilot-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OverlayState(readDefaults: defaults)
        precondition(state.latestRun == nil, "State initialization must not bypass startup recovery")
        let recovered = TaskRun(sessionId: "startup", turnId: "recovered", finishedAtMs: 2,
                                publication: PublicationInfo(revision: 1, completedAtMs: 2))
        state.update(run: recovered, recovery: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.latestRun?.id == recovered.id)
        precondition(!state.isExpanded, "Startup recovery must remain silent")
        precondition(state.hasUnreadResult, "An unseen recovered result must be indicated")
        state.expand(notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.hasUnreadResult, "Automatic expansion must not acknowledge a result")
        state.openLatest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!state.hasUnreadResult, "Explicit open must acknowledge the displayed result")
        let newer = TaskRun(sessionId: "other-chat", turnId: "recovered", finishedAtMs: 3,
                            publication: PublicationInfo(revision: 1, completedAtMs: 3))
        state.update(run: newer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.hasUnreadResult, "Another chat's turn remains unread")
        state.selectTab(.history)
        state.expand()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.hasUnreadResult, "Opening history must not acknowledge an unseen latest result")
        guard let accountTab = OverlayTab(rawValue: "Account") else {
            preconditionFailure("Account must be a navigation destination, including for IPC status")
        }
        state.selectTab(accountTab)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.activeTab == accountTab)
        precondition(state.hasUnreadResult, "Viewing account settings cannot acknowledge a task result")
        state.inspect(run: recovered)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.activeTab == .inspector, "Selecting history from Account must display the selected turn")
        precondition(state.hasUnreadResult, "Viewing old history cannot acknowledge the latest result")
        state.selectTab(accountTab)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        state.jumpToLive()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.activeTab == .inspector, "Jumping to latest from Account must display that turn")
        precondition(!state.hasUnreadResult)
        let restored = OverlayState(readDefaults: defaults)
        restored.update(run: newer, recovery: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!restored.hasUnreadResult, "Acknowledgment survives restart")
        let host = NSRect(x: 0, y: 0, width: 166, height: 76)
        precondition(OverlayCompactHitRegion.contains(NSPoint(x: 20, y: 38), in: host, expanded: false, docked: false), "Capsule text/icon sides must be clickable")
        precondition(!OverlayCompactHitRegion.contains(NSPoint(x: 2, y: 2), in: host, expanded: false, docked: false))
        try testRefreshIsQuietThenUpdateExpandsOnce()
        print("Overlay startup, IPC refresh, unread result and capsule hit-region tests passed")
    }

    private static func testRefreshIsQuietThenUpdateExpandsOnce() throws {
        let suffix = String(UUID().uuidString.prefix(8))
        let root = URL(fileURLWithPath: "/tmp/fp-ipc-\(suffix)")
        let socketPath = root.appendingPathComponent("overlay.sock").path
        let telemetry = root.appendingPathComponent("codex-flow/telemetry")
        let lastURL = telemetry.appendingPathComponent("last.json")
        let previousHome = getenv("CODEX_HOME").map { String(cString: $0) }
        setenv("CODEX_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) }
            else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: telemetry, withIntermediateDirectories: true)
        let run = TaskRun(
            sessionId: "chat-refresh",
            turnId: "turn-1",
            finishedAtMs: 1,
            status: "completed",
            publication: PublicationInfo(revision: 1, completedAtMs: 1)
        )
        try JSONEncoder().encode(run).write(to: lastURL)

        let defaults = UserDefaults(suiteName: "flowpilot-ipc-\(suffix)")!
        defer { defaults.removePersistentDomain(forName: "flowpilot-ipc-\(suffix)") }
        let state = OverlayState(readDefaults: defaults)
        let server = IPCService.Server(state: state, socketPath: socketPath)
        defer { server.stop() }

        let refreshed = try send("refresh", socketPath: socketPath)
        precondition(refreshed.contains("\"ok\": true"), "refresh must acknowledge success")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.latestRun?.id == run.id, "quiet refresh must load the published snapshot")
        precondition(!state.isExpanded, "quiet refresh must not expand the overlay")
        precondition(state.hasUnreadResult, "quiet refresh must preserve unread state")

        var late = run
        late.publication = PublicationInfo(revision: 2, completedAtMs: 1)
        try JSONEncoder().encode(late).write(to: lastURL)
        _ = try send("refresh", socketPath: socketPath)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let updated = try send("update", socketPath: socketPath)
        precondition(updated.contains("\"ok\": true"), "update must acknowledge success")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.isExpanded, "completion update must expand the overlay")
        precondition(state.hasUnreadResult, "automatic expansion must not acknowledge the result")
        state.collapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(!state.isExpanded, "test setup must collapse the overlay")

        let repeated = try send("update", socketPath: socketPath)
        precondition(repeated.contains("\"ok\": true"), "repeated update must acknowledge success")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(!state.isExpanded, "repeated update must not reexpand an already presented result")
        let older = TaskRun(sessionId: "older-chat", turnId: "turn-1", finishedAtMs: 0,
                            publication: PublicationInfo(revision: 2, completedAtMs: 0))
        let olderURL = telemetry.appendingPathComponent("older.json")
        try JSONEncoder().encode(older).write(to: olderURL)
        _ = try send("update " + olderURL.path, socketPath: socketPath)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.isExpanded)
        precondition(state.latestRun?.id == run.id)
        precondition(state.notificationRun?.id == older.id)
        _ = try send("refresh", socketPath: socketPath)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.notificationRun?.id == older.id)

    }

    private static func send(_ command: String, socketPath: String) throws -> String {
        let box = CommandResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(IPCService.sendCommand(command, socketPath: socketPath))
        }
        let deadline = Date().addingTimeInterval(2)
        while box.value == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let result = box.value else {
            throw IPCRefreshTestError(message: "timed out waiting for IPC response to \(command)")
        }
        guard result.0 else {
            throw IPCRefreshTestError(message: "IPC command failed: \(result.1)")
        }
        return result.1
    }
}

private final class CommandResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Bool, String)?

    func set(_ value: (Bool, String)) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: (Bool, String)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct IPCRefreshTestError: Error {
    let message: String
}
