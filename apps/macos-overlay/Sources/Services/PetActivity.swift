import Foundation

/// The small event contract shared by the telemetry writer and the native
/// overlay. Unknown JSON fields are intentionally ignored so the Python
/// snapshot can carry reducer metadata without widening the Swift API.
public struct PetActivityEvent: Codable, Equatable {
    public let schemaVersion: Int
    public let event: String
    public let sessionID: String
    public let turnID: String
    public let sequence: Int
    public let timestampMilliseconds: Int64
    public let startedAtMilliseconds: Int64
    public let source: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
        case sessionID = "session_id"
        case turnID = "turn_id"
        case sequence
        case timestampMilliseconds = "timestamp_ms"
        case startedAtMilliseconds = "started_at_ms"
        case source
    }

    public init(
        schemaVersion: Int,
        event: String,
        sessionID: String,
        turnID: String,
        sequence: Int,
        timestampMilliseconds: Int64,
        startedAtMilliseconds: Int64,
        source: String
    ) {
        self.schemaVersion = schemaVersion
        self.event = event
        self.sessionID = sessionID
        self.turnID = turnID
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.startedAtMilliseconds = startedAtMilliseconds
        self.source = source
    }
}

public struct PetActivityTransition: Equatable {
    public let accepted: Bool
    public let taskState: PetState?
    public let transient: PetState?
    public let clear: Bool
    public let unavailable: Bool

    public init(
        accepted: Bool,
        taskState: PetState? = nil,
        transient: PetState? = nil,
        clear: Bool = false,
        unavailable: Bool = false
    ) {
        self.accepted = accepted
        self.taskState = taskState
        self.transient = transient
        self.clear = clear
        self.unavailable = unavailable
    }
}

/// Reducer for live activity. It accepts ordered events for one turn, ignores
/// stale or duplicate hook deliveries, and lets a later turn take over only
/// when its declared start is newer than the current turn.
public struct PetActivityTracker {
    public static let activityTTLMilliseconds: Int64 = 120_000

    private static let events: Set<String> = [
        "started", "running", "waiting", "review", "succeeded", "failed", "completed", "aborted",
    ]
    private static let taskEvents: Set<String> = ["started", "running", "waiting", "review"]

    private var activeSessionID: String?
    private var activeTurnID: String?
    private var startedAtMilliseconds: Int64?
    private var lastSequence = 0
    private var lastTimestampMilliseconds: Int64 = 0
    private var effectiveState: PetState?
    private var terminalEvent: String?

    public init() {}

    public mutating func consume(
        _ event: PetActivityEvent,
        nowMilliseconds: Int64
    ) -> PetActivityTransition {
        guard event.schemaVersion == 1,
              Self.events.contains(event.event),
              !event.sessionID.isEmpty,
              !event.turnID.isEmpty,
              event.sequence > 0,
              event.timestampMilliseconds >= 0,
              event.startedAtMilliseconds >= 0 else {
            return PetActivityTransition(accepted: false)
        }
        guard nowMilliseconds - event.timestampMilliseconds <= Self.activityTTLMilliseconds else {
            return PetActivityTransition(accepted: false)
        }

        let sameTurn = activeSessionID == event.sessionID && activeTurnID == event.turnID
        if !sameTurn, let startedAtMilliseconds,
           event.startedAtMilliseconds <= startedAtMilliseconds {
            return PetActivityTransition(accepted: false)
        }
        if sameTurn {
            guard event.sequence > lastSequence else {
                return PetActivityTransition(accepted: false)
            }
            if terminalEvent != nil, event.event != "completed" {
                return PetActivityTransition(accepted: false)
            }
        } else {
            resetForTurn(event)
        }

        let previousState = effectiveState
        let previousTerminal = terminalEvent
        activeSessionID = event.sessionID
        activeTurnID = event.turnID
        startedAtMilliseconds = sameTurn ? startedAtMilliseconds : event.startedAtMilliseconds
        lastSequence = event.sequence
        lastTimestampMilliseconds = event.timestampMilliseconds

        var nextTaskState: PetState?
        var transient: PetState?
        var clear = false
        var unavailable = false
        switch event.event {
        case "started", "running":
            effectiveState = .running
        case "waiting":
            effectiveState = .waiting
        case "review":
            effectiveState = .review
        case "succeeded":
            effectiveState = .idle
            terminalEvent = "succeeded"
            transient = .jumping
        case "failed":
            effectiveState = .failed
            terminalEvent = "failed"
        case "completed":
            if previousTerminal == nil {
                effectiveState = .idle
                terminalEvent = "completed"
                transient = .waving
            }
        case "aborted":
            terminalEvent = "aborted"
            effectiveState = nil
            clear = true
            unavailable = true
        default:
            return PetActivityTransition(accepted: false)
        }

        if event.event == "completed", previousTerminal != nil {
            // Preserve the terminal state from the earlier explicit result.
            effectiveState = previousState
            terminalEvent = previousTerminal
        }
        if effectiveState != previousState {
            nextTaskState = effectiveState
        }
        return PetActivityTransition(
            accepted: true,
            taskState: nextTaskState,
            transient: transient,
            clear: clear,
            unavailable: unavailable
        )
    }

    public mutating func expire(nowMilliseconds: Int64) -> PetActivityTransition {
        if terminalEvent != nil {
            return PetActivityTransition(accepted: false)
        }
        guard activeSessionID != nil,
              nowMilliseconds - lastTimestampMilliseconds > Self.activityTTLMilliseconds else {
            return PetActivityTransition(accepted: false)
        }
        activeSessionID = nil
        activeTurnID = nil
        startedAtMilliseconds = nil
        lastSequence = 0
        lastTimestampMilliseconds = 0
        effectiveState = nil
        terminalEvent = nil
        return PetActivityTransition(accepted: true, clear: true, unavailable: true)
    }

    private mutating func resetForTurn(_ event: PetActivityEvent) {
        activeSessionID = event.sessionID
        activeTurnID = event.turnID
        startedAtMilliseconds = event.startedAtMilliseconds
        lastSequence = 0
        lastTimestampMilliseconds = 0
        effectiveState = nil
        terminalEvent = nil
    }
}
