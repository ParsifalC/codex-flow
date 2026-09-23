import AppKit
import Foundation

@main
struct PetOverlayInteractionTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/tmp/pet-overlay-\(UUID().uuidString.prefix(8))")
        let previousHome = getenv("CODEX_HOME").map { String(cString: $0) }
        setenv("CODEX_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) }
            else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: root)
        }

        let current = root.appendingPathComponent("codex-flow/pets/current")
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("default".utf8).write(to: current)
        let suite = "pet-overlay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OverlayState(readDefaults: defaults)
        let petBounds = NSRect(origin: .zero, size: OverlayCompactLayout.petHostSize)
        precondition(OverlayCompactHitRegion.contains(NSPoint(x: 64, y: 70), in: petBounds, expanded: false, docked: false, pet: true), "The pet must remain draggable")
        precondition(OverlayCompactHitRegion.contains(NSPoint(x: 64, y: 16), in: petBounds, expanded: false, docked: false, pet: true), "The consumption label must remain clickable")
        precondition(!OverlayCompactHitRegion.contains(NSPoint(x: 4, y: 70), in: petBounds, expanded: false, docked: false, pet: true), "Transparent side margins must pass through")

        state.setPetVisibility(true)
        precondition(state.petAnimator.timerIsRunning, "A visible compact pet must animate")
        state.setPetVisibility(false)
        state.refreshPetVisibility(reduceMotion: true)
        state.refreshPetVisibility(reduceMotion: false)
        var reloaded = false
        state.reloadPetAsync { _ in reloaded = true }
        let reloadDeadline = Date().addingTimeInterval(5)
        while !reloaded && Date() < reloadDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(reloaded)
        state.refreshPetVisibility(reduceMotion: false)
        precondition(!state.petAnimator.timerIsRunning, "Reload and motion changes must preserve window occlusion")
        state.setPetVisibility(true)
        state.isExpanded = true
        state.refreshPetVisibility(reduceMotion: false)
        precondition(!state.petAnimator.timerIsRunning, "An expanded overlay must stop animation")
        state.isExpanded = false
        state.refreshPetVisibility(reduceMotion: false)
        precondition(state.petAnimator.timerIsRunning, "Collapsing a visible overlay must resume animation")
        state.setPetVisibility(false)

        state.setTaskState(.running)
        state.playPetHover()
        precondition(state.petAnimator.state == .waving, "Hover must trigger one wave through OverlayState")
        state.beginDrag(direction: .right)
        precondition(state.petAnimator.state == .runningRight, "A real right drag must select the right-running row")
        state.endDrag()
        precondition(state.petAnimator.state == .running, "Mouse-up must restore the task state")

        state.setTaskState(.waiting)
        state.playPetHover()
        precondition(state.petAnimator.state == .waiting, "Waiting must keep priority over hover")
        state.setTaskState(.failed)
        state.playPetHover()
        precondition(state.petAnimator.state == .failed, "Failed must keep priority over hover")
        state.setTaskState(.running)
        state.playTransient(.jumping)
        precondition(state.petAnimator.state == .jumping, "Explicit transient events must reach the reducer")
        state.clear()
        precondition(state.petAnimator.state == .idle, "Clear must return the pet to idle")
        state.stop()

        let socketPath = root.appendingPathComponent("codex-flow/overlay.sock").path
        let server = IPCService.Server(state: state, socketPath: socketPath)
        defer { server.stop() }
        let responseBox = ResponseBox()
        let response = send("pet reload", socketPath: socketPath, box: responseBox)
        precondition(response.success && response.response.contains("\"ok\":true"), "pet reload must report built-in success")

        let fixtureRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PET_FIXTURES_ROOT"] ?? "")
        let packageRoot = root.appendingPathComponent("codex-flow/pets/installed/synthetic-v2")
        try FileManager.default.createDirectory(at: packageRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("synthetic-v2"), to: packageRoot)
        try Data("synthetic-v2".utf8).write(to: current)
        state.isDocked = true
        let accepted = send("pet reload", socketPath: socketPath, box: ResponseBox())
        precondition(accepted.success && accepted.response.contains("\"ok\":true"), "valid package reload must acknowledge after decode")
        precondition(!state.isDocked, "Loading a pet must leave capsule docking")
        precondition(state.petResource?.id == "synthetic-v2", "valid package reload must publish the decoded pet")

        state.setPetVisibility(true)
        state.clear()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let result = TaskRun(sessionId: "result-session", turnId: "result-turn", finishedAtMs: Double(now),
                             publication: PublicationInfo(revision: 1, completedAtMs: Double(now)))
        state.update(run: result, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(!state.isExpanded && state.petAnimator.state == .jumping, "Pet completion should jump without opening the panel")
        precondition(state.petUnreadCount == 1 && state.petCompletionNotice?.id == result.id, "A completion must show a notice and retain an unread badge")
        let firstNotice = state.petCompletionNotice?.id
        state.petAnimator.advance(by: 180)
        let completed = PetActivityEvent(schemaVersion: 1, event: "completed", sessionID: "result-session", turnID: "result-turn", sequence: 1, timestampMilliseconds: now, startedAtMilliseconds: now, source: "test")
        let beforeLive = state.petAnimator.frameIndex
        _ = state.handlePetActivity(completed)
        precondition(state.petAnimator.frameIndex == beforeLive, "Live completion arriving second must not restart the publication jump")
        state.petAnimator.advance(by: 2_000)
        precondition(state.petAnimator.state == .jumping, "Completion must stay visible beyond a brief gesture")
        state.petAnimator.playHover()
        precondition(state.petAnimator.state == .jumping, "Hover must not replace a completion reminder")
        state.petAnimator.advance(by: 5_000)
        precondition(state.petAnimator.state == .idle)
        state.update(run: result, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.petAnimator.state == .idle, "Repeated publication must not celebrate twice")

        precondition(state.petUnreadCount == 1 && state.petCompletionNotice?.id == firstNotice, "Duplicate publication must not create another unread item")

        let second = PetActivityEvent(schemaVersion: 1, event: "succeeded", sessionID: "second", turnID: "second", sequence: 1, timestampMilliseconds: now + 1, startedAtMilliseconds: now + 1, source: "test")
        _ = state.handlePetActivity(second)
        state.petAnimator.advance(by: 180)
        let secondRun = TaskRun(sessionId: "second", turnId: "second", finishedAtMs: Double(now + 1),
                                publication: PublicationInfo(revision: 1, completedAtMs: Double(now + 1)))
        state.update(run: secondRun, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(state.petAnimator.frameIndex > 0, "Publication arriving second must not restart the live jump")
        state.petAnimator.advance(by: 2_000)
        precondition(state.petAnimator.state == .jumping, "Completion must stay visible beyond a brief gesture")
        state.petAnimator.playHover()
        precondition(state.petAnimator.state == .jumping, "Hover must not replace a completion reminder")
        state.petAnimator.advance(by: 5_000)
        precondition(state.petAnimator.state == .idle)

        precondition(state.petUnreadCount == 2, "Concurrent completions must accumulate")
        state.markResultViewed(secondRun)
        precondition(state.petUnreadCount == 1, "Reading one result must preserve the other unread result")
        precondition(state.petCompletionNotice == nil, "Reading the displayed notice must dismiss it")
        state.markResultViewed(result)
        precondition(state.petUnreadCount == 0, "Reading all results must clear the badge")

        let expiring = TaskRun(sessionId: "expiry", turnId: "expiry", finishedAtMs: Double(now + 2),
                               publication: PublicationInfo(revision: 1, completedAtMs: Double(now + 2)))
        state.update(run: expiring, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.petCompletionNotice?.id == expiring.id)
        RunLoop.main.run(until: Date().addingTimeInterval(8.1))
        precondition(state.petCompletionNotice == nil && state.petUnreadCount == 1,
                     "Expiry must hide the bubble without marking the result read")
        state.update(run: expiring, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.petCompletionNotice == nil, "Duplicate delivery after expiry must not reopen the bubble")

        try Data("../synthetic-v2".utf8).write(to: current)
        let rejected = send("pet reload", socketPath: socketPath, box: ResponseBox())
        precondition(rejected.success && rejected.response.contains("\"ok\":false"), "invalid package reload must report an error")
        precondition(state.petResource == nil, "invalid package reload must fall back to built-in rendering")
        print("Pet overlay hover, drag, priority and IPC tests passed")
    }

    private static func send(
        _ command: String,
        socketPath: String,
        box: ResponseBox
    ) -> (success: Bool, response: String) {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = IPCService.sendCommand(command, socketPath: socketPath)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let value = box.value else {
            preconditionFailure("IPC response was not captured")
        }
        return value
    }

    private final class ResponseBox: NSObject {
        var value: (success: Bool, response: String)?
    }
}
