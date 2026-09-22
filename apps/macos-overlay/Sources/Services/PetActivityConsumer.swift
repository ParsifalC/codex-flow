import Foundation

/// Applies tracker transitions to the existing native animator and restores a
/// still-live snapshot when the overlay starts. It does not update telemetry
/// publication or infer an outcome from a missing event.
public final class PetActivityConsumer {
    private weak var state: OverlayState?
    private let snapshotURL: URL
    private var tracker = PetActivityTracker()
    private var expiryTimer: DispatchSourceTimer?

    public init(state: OverlayState, snapshotURL: URL? = nil) {
        self.state = state
        if let snapshotURL {
            self.snapshotURL = snapshotURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
            self.snapshotURL = URL(fileURLWithPath: codexHome)
                .appendingPathComponent("codex-flow/telemetry/activity/state.json")
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.expire() }
        timer.resume()
        expiryTimer = timer
    }

    deinit {
        expiryTimer?.cancel()
    }

    @discardableResult
    public func consume(_ event: PetActivityEvent, nowMilliseconds: Int64? = nil) -> PetActivityTransition {
        let clock = nowMilliseconds ?? Self.clockMilliseconds()
        apply(tracker.expire(nowMilliseconds: clock))
        let transition = tracker.consume(event, nowMilliseconds: clock)
        apply(transition, event: event)
        return transition
    }

    public func consumeJSON(_ payload: String, nowMilliseconds: Int64? = nil) -> String {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(PetActivityEvent.self, from: data) else {
            return Self.response(ok: false, accepted: false, error: "invalid_event")
        }
        let transition = consume(event, nowMilliseconds: nowMilliseconds)
        guard transition.accepted else {
            return Self.response(ok: false, accepted: false, error: "stale_event")
        }
        return Self.response(ok: true, accepted: true)
    }

    public func recover(nowMilliseconds: Int64? = nil) {
        guard let data = try? Data(contentsOf: snapshotURL),
              let event = try? JSONDecoder().decode(PetActivityEvent.self, from: data) else {
            return
        }
        let clock = nowMilliseconds ?? Self.clockMilliseconds()
        let terminalEvents = ["succeeded", "failed", "completed", "aborted"]
        if clock - event.timestampMilliseconds > PetActivityTracker.activityTTLMilliseconds,
           !terminalEvents.contains(event.event) {
            apply(PetActivityTransition(accepted: true, clear: true, unavailable: true))
            return
        }
        let transition = tracker.consume(
            event,
            nowMilliseconds: terminalEvents.contains(event.event) ? event.timestampMilliseconds : clock
        )
        apply(transition, event: event, recovering: true)
    }

    @discardableResult
    public func expire(nowMilliseconds: Int64? = nil) -> PetActivityTransition {
        let transition = tracker.expire(nowMilliseconds: nowMilliseconds ?? Self.clockMilliseconds())
        apply(transition)
        return transition
    }

    private func apply(_ transition: PetActivityTransition, event: PetActivityEvent? = nil, recovering: Bool = false) {
        guard let state else { return }
        if transition.unavailable {
            state.clear()
            state.markPetActivityUnavailable()
            return
        }
        if transition.clear {
            state.clear()
        }
        if let taskState = transition.taskState {
            state.setTaskState(taskState, preservingTransient: transition.transient != nil)
        }
        if let transient = transition.transient, !recovering {
            if let event, transient == .jumping || transient == .waving {
                state.celebratePetResult(session: event.sessionID, turn: event.turnID)
            } else {
                state.playTransient(transient)
            }
        }
        if transition.accepted {
            state.markPetActivityAvailable()
        }
    }

    private static func clockMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func response(ok: Bool, accepted: Bool, error: String? = nil) -> String {
        var values = ["ok": ok, "accepted": accepted] as [String: Any]
        values["action"] = "pet_event"
        if let error { values["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"accepted\":false,\"error\":\"encoding\"}"
        }
        return result
    }
}
