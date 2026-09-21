import Foundation

/// The nine rows used by the Petdex v1/v2 native atlas. The raw values match
/// the wire/resource names; Swift identifiers use camel case for the rows
/// whose names contain a hyphen.
public enum PetState: String, CaseIterable, Codable, Equatable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review
}

public struct PetFrame: Equatable {
    public let column: Int
    public let durationMilliseconds: Int

    public init(column: Int, durationMilliseconds: Int) {
        self.column = column
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct PetAnimationDefinition: Equatable {
    public let row: Int
    public let frames: [PetFrame]

    public init(row: Int, frames: [PetFrame]) {
        self.row = row
        self.frames = frames
    }
}

public enum PetAnimationTable {
    public static func definition(for state: PetState) -> PetAnimationDefinition {
        switch state {
        case .idle:
            return PetAnimationDefinition(row: 0, frames: [
                PetFrame(column: 0, durationMilliseconds: 280),
                PetFrame(column: 1, durationMilliseconds: 110),
                PetFrame(column: 2, durationMilliseconds: 110),
                PetFrame(column: 3, durationMilliseconds: 140),
                PetFrame(column: 4, durationMilliseconds: 140),
                PetFrame(column: 5, durationMilliseconds: 320)
            ])
        case .runningRight:
            return uniform(row: 1, count: 8, durationMilliseconds: 120, lastDurationMilliseconds: 220)
        case .runningLeft:
            return uniform(row: 2, count: 8, durationMilliseconds: 120, lastDurationMilliseconds: 220)
        case .waving:
            return uniform(row: 3, count: 4, durationMilliseconds: 140, lastDurationMilliseconds: 280)
        case .jumping:
            return uniform(row: 4, count: 5, durationMilliseconds: 140, lastDurationMilliseconds: 280)
        case .failed:
            return uniform(row: 5, count: 8, durationMilliseconds: 140, lastDurationMilliseconds: 240)
        case .waiting:
            return uniform(row: 6, count: 6, durationMilliseconds: 150, lastDurationMilliseconds: 260)
        case .running:
            return uniform(row: 7, count: 6, durationMilliseconds: 120, lastDurationMilliseconds: 220)
        case .review:
            return uniform(row: 8, count: 6, durationMilliseconds: 150, lastDurationMilliseconds: 280)
        }
    }

    private static func uniform(
        row: Int,
        count: Int,
        durationMilliseconds: Int,
        lastDurationMilliseconds: Int
    ) -> PetAnimationDefinition {
        PetAnimationDefinition(
            row: row,
            frames: (0..<count).map { index in
                PetFrame(
                    column: index,
                    durationMilliseconds: index == count - 1 ? lastDurationMilliseconds : durationMilliseconds
                )
            }
        )
    }
}

public enum PetDragDirection: Equatable {
    case left
    case right
}

/// Pure state reducer shared by the view animator and the live event bridge.
/// Task state is kept separately from finite interaction states so an ending
/// wave/jump or a completed drag can return to the real task state.
public struct PetAnimationReducer {
    public private(set) var taskState: PetState = .idle
    public private(set) var state: PetState = .idle
    public private(set) var frameIndex: Int = 0

    private var elapsedMilliseconds = 0
    private var transientState: PetState?
    private var dragDirection: PetDragDirection?

    public init() {}

    public mutating func setTaskState(_ state: PetState) {
        taskState = state
        if dragDirection != nil {
            // A task event may arrive while the pointer is still dragging.
            // Keep the directional row until mouse-up, then return to this
            // newer task state.
            return
        }
        transientState = nil
        self.state = state
        frameIndex = 0
        elapsedMilliseconds = 0
    }

    /// Plays a finite interaction. Waiting and failed have priority over
    /// hover waves; an explicit failed signal is still allowed to enter the
    /// failed row from any ordinary task state.
    public mutating func playTransient(_ state: PetState) {
        guard state == .waving || state == .jumping || state == .failed else { return }
        guard taskState != .waiting || state == .failed else { return }
        guard taskState != .failed || state == .failed else { return }
        guard dragDirection == nil else { return }
        transientState = state
        self.state = state
        frameIndex = 0
        elapsedMilliseconds = 0
    }

    public mutating func beginDrag(direction: PetDragDirection) {
        dragDirection = direction
        transientState = nil
        state = direction == .left ? .runningLeft : .runningRight
        frameIndex = 0
        elapsedMilliseconds = 0
    }

    public mutating func endDrag() {
        guard dragDirection != nil else { return }
        dragDirection = nil
        transientState = nil
        state = taskState
        frameIndex = 0
        elapsedMilliseconds = 0
    }

    /// Clears a terminal/temporary state and returns the reducer to idle.
    public mutating func clear() {
        taskState = .idle
        state = .idle
        transientState = nil
        dragDirection = nil
        frameIndex = 0
        elapsedMilliseconds = 0
    }

    /// Stops frame progression while keeping the current task state. The
    /// animator owns the timer; this hook resets the reducer's partial frame
    /// progress when the view is hidden or expanded.
    public mutating func stop() {
        transientState = nil
        dragDirection = nil
        state = taskState
        frameIndex = 0
        elapsedMilliseconds = 0
    }

    public mutating func advance(by milliseconds: Int) {
        guard milliseconds > 0 else { return }
        var remaining = milliseconds
        while remaining > 0 {
            let frames = PetAnimationTable.definition(for: state).frames
            guard !frames.isEmpty else { return }
            let frame = frames[min(frameIndex, frames.count - 1)]
            let untilNext = max(1, frame.durationMilliseconds - elapsedMilliseconds)
            if remaining < untilNext {
                elapsedMilliseconds += remaining
                return
            }

            remaining -= untilNext
            elapsedMilliseconds = 0
            if frameIndex + 1 < frames.count {
                frameIndex += 1
                continue
            }

            if state == .failed {
                // Failed remains on its final frame until the task state is
                // explicitly cleared or replaced.
                frameIndex = frames.count - 1
                return
            }
            if let transientState, transientState == .waving || transientState == .jumping {
                self.transientState = nil
                state = taskState
                frameIndex = 0
                continue
            }
            frameIndex = 0
        }
    }
}

public struct PetReloadOutcome {
    public let accepted: Bool
    public let selectedID: String
    public let error: String?

    public init(accepted: Bool, selectedID: String, error: String? = nil) {
        self.accepted = accepted
        self.selectedID = selectedID
        self.error = error
    }

    public var json: String {
        var object: [String: Any] = [
            "ok": accepted,
            "action": "pet_reload",
            "pet": selectedID
        ]
        if let error {
            object["error"] = error
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return accepted ? "{\"ok\":true,\"action\":\"pet_reload\"}" : "{\"ok\":false,\"action\":\"pet_reload\"}"
        }
        return value
    }
}
