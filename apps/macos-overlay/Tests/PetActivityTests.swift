import Foundation

@main
struct PetActivityTests {
    static func main() throws {
        var tracker = PetActivityTracker()
        let started = event("started", sequence: 1, timestamp: 1_000, startedAt: 1_000)
        let first = tracker.consume(started, nowMilliseconds: 1_000)
        precondition(first.accepted && first.taskState == .running)

        let duplicate = tracker.consume(event("running", sequence: 1, timestamp: 1_001, startedAt: 1_000), nowMilliseconds: 1_001)
        precondition(!duplicate.accepted, "Duplicate sequence must be ignored")
        let heartbeat = tracker.consume(event("running", sequence: 2, timestamp: 1_002, startedAt: 1_000), nowMilliseconds: 1_002)
        precondition(heartbeat.accepted && heartbeat.taskState == nil, "Same effective state must not reset the animator")

        let success = tracker.consume(event("succeeded", sequence: 3, timestamp: 1_003, startedAt: 1_000), nowMilliseconds: 1_003)
        precondition(success.accepted && success.transient == .jumping)
        let completed = tracker.consume(event("completed", sequence: 4, timestamp: 1_004, startedAt: 1_000), nowMilliseconds: 1_004)
        precondition(completed.accepted && completed.transient == nil, "Completion must not celebrate a successful turn twice")
        let lateTool = tracker.consume(event("running", sequence: 5, timestamp: 1_005, startedAt: 1_000), nowMilliseconds: 1_005)
        precondition(!lateTool.accepted, "Post-terminal activity must not restore running")

        let oldTurn = tracker.consume(event("started", session: "other", turn: "old", sequence: 1, timestamp: 900, startedAt: 900), nowMilliseconds: 1_006)
        precondition(!oldTurn.accepted, "An older turn must not replace the active turn")

        let terminalStillVisible = tracker.expire(nowMilliseconds: 1_004 + PetActivityTracker.activityTTLMilliseconds + 1)
        precondition(!terminalStillVisible.unavailable, "Explicit terminal results remain visible until a new task")
        for outcome in ["succeeded", "failed"] {
            var terminalTracker = PetActivityTracker()
            _ = terminalTracker.consume(event(outcome, sequence: 1, timestamp: 2_000, startedAt: 2_000), nowMilliseconds: 2_000)
            let interrupted = terminalTracker.consume(event("aborted", sequence: 2, timestamp: 2_001, startedAt: 2_000), nowMilliseconds: 2_001)
            precondition(!interrupted.accepted && !interrupted.clear && !interrupted.unavailable, "Late Interrupt must preserve explicit outcome")
        }
        for outcome in ["succeeded", "failed", "completed", "aborted"] {
            for late in ["succeeded", "failed", "aborted"] {
                var immutable = PetActivityTracker()
                _ = immutable.consume(event(outcome, sequence: 1, timestamp: 2_000, startedAt: 2_000), nowMilliseconds: 2_000)
                let transition = immutable.consume(event(late, sequence: 2, timestamp: 2_001, startedAt: 2_000), nowMilliseconds: 2_001)
                precondition(!transition.accepted && transition.transient == nil, "Terminal outcomes cannot be changed or celebrated twice")
            }
        }
        var activeTracker = PetActivityTracker()
        _ = activeTracker.consume(event("started", session: "fresh", turn: "fresh", sequence: 1, timestamp: 2_000, startedAt: 2_000), nowMilliseconds: 2_000)
        let expired = activeTracker.expire(nowMilliseconds: 2_000 + PetActivityTracker.activityTTLMilliseconds + 1)
        precondition(expired.unavailable && expired.clear)
        print("Pet activity ordering, dedupe and expiry tests passed")
    }

    private static func event(
        _ name: String,
        session: String = "session",
        turn: String = "turn",
        sequence: Int,
        timestamp: Int64,
        startedAt: Int64
    ) -> PetActivityEvent {
        PetActivityEvent(
            schemaVersion: 1,
            event: name,
            sessionID: session,
            turnID: turn,
            sequence: sequence,
            timestampMilliseconds: timestamp,
            startedAtMilliseconds: startedAt,
            source: "test"
        )
    }
}
