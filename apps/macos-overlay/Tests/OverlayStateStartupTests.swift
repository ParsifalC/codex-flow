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
        let state = OverlayState()
        precondition(state.latestRun == nil, "State initialization must not bypass startup recovery")
        let recovered = TaskRun(sessionId: "startup", turnId: "recovered", finishedAtMs: 2,
                                publication: PublicationInfo(revision: 1, completedAtMs: 2))
        state.update(run: recovered, recovery: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.latestRun?.id == recovered.id)
        precondition(!state.isExpanded, "Startup recovery must remain silent")
        print("Overlay state startup tests passed")
    }
}
