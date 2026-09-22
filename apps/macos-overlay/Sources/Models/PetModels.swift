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
            return uniform(row: 1, count: 8, durationMilliseconds: 120, lastDurationMilliseconds: 120)
        case .runningLeft:
            return uniform(row: 2, count: 8, durationMilliseconds: 120, lastDurationMilliseconds: 120)
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

/// Personality changes pauses and repetitions, never the atlas's row/column map.
struct PetPlaybackProfile: Equatable {
    let resourceID: String

    init(resourceID: String = "default") {
        self.resourceID = ["dasheng", "deepseek", "doraemon", "lulu-capybara-2", "noir-webling"].contains(resourceID)
            ? resourceID : "default"
    }

    var waveCycles: Int { resourceID == "deepseek" || resourceID == "noir-webling" ? 3 : 2 }
    var jumpPause: Int { resourceID == "lulu-capybara-2" ? 250 : (resourceID == "deepseek" ? 220 : 200) }
    var landingPause: Int { resourceID == "lulu-capybara-2" ? 80 : 0 }
    var waitingPause: Int { resourceID == "lulu-capybara-2" ? 500 : (resourceID == "deepseek" ? 450 : 400) }
    var thoughtfulPause: Int { resourceID == "deepseek" || resourceID == "lulu-capybara-2" ? 700 : 550 }
    var failedPause: Int { resourceID == "lulu-capybara-2" ? 1_200 : (resourceID == "deepseek" ? 1_100 : 1_000) }
    var failedFrame: Int { resourceID == "deepseek" || resourceID == "lulu-capybara-2" ? 3 : 4 }
    var reviewFrame: Int { resourceID == "dasheng" ? 2 : (resourceID == "lulu-capybara-2" ? 4 : (resourceID == "noir-webling" ? 1 : 3)) }
    var turnPause: Int { resourceID == "lulu-capybara-2" ? 800 : 600 }
    var quietRange: ClosedRange<Int> { (resourceID == "noir-webling" ? 30_000 : 20_000)...35_000 }
    var idleRange: ClosedRange<Int> {
        (resourceID == "noir-webling" ? 4_500 : (resourceID == "lulu-capybara-2" ? 4_000 : 3_000))...6_000
    }
}

struct PetPlaybackRandom {
    private var value: UInt64
    init(seed: UInt64) { value = seed }
    mutating func next(_ range: ClosedRange<Int>) -> Int {
        value = value &* 6364136223846793005 &+ 1442695040888963407
        return range.lowerBound + Int(value % UInt64(range.upperBound - range.lowerBound + 1))
    }
}

/// A playback frame points into the canonical row's frame array. Holds may
/// reference the same atlas cell again without inventing extra sprite columns.
struct PetPlaybackFrame {
    let state: PetState
    let frameIndex: Int
    let duration: Int
    var from: Double = 0
    var to: Double = 0
}

struct PetPlaybackTimeline {
    var frames: [PetPlaybackFrame]
    var duration: Int { frames.reduce(0) { $0 + $1.duration } }

    static func cycle(_ state: PetState) -> Self {
        Self(frames: PetAnimationTable.definition(for: state).frames.enumerated().map {
            PetPlaybackFrame(state: state, frameIndex: $0.offset, duration: $0.element.durationMilliseconds)
        })
    }

    static func idle(dwell: Int, holdFirst: Bool = false) -> Self {
        let rest = PetPlaybackFrame(state: .idle, frameIndex: 0, duration: dwell)
        return Self(frames: holdFirst ? [rest] + cycle(.idle).frames : cycle(.idle).frames + [rest])
    }

    static func action(_ state: PetState, profile: PetPlaybackProfile) -> Self {
        let cycles: Int
        switch state {
        case .waving: cycles = profile.waveCycles
        case .jumping, .waiting, .review, .runningLeft, .runningRight: cycles = 2
        case .running: cycles = 3
        default: cycles = 1
        }
        var frames: [PetPlaybackFrame] = []
        for repetition in 0..<cycles {
            for frame in cycle(state).frames {
                frames.append(frame)
                if state == .failed && frame.frameIndex == profile.failedFrame {
                    frames.append(PetPlaybackFrame(state: state, frameIndex: profile.failedFrame, duration: profile.failedPause))
                }
                if state == .review && repetition == 0 && frame.frameIndex == profile.reviewFrame {
                    frames.append(PetPlaybackFrame(state: state, frameIndex: profile.reviewFrame, duration: profile.thoughtfulPause))
                }
            }
            if state == .jumping && profile.landingPause > 0 {
                frames.append(PetPlaybackFrame(state: state, frameIndex: 4, duration: profile.landingPause))
            }
            if repetition + 1 < cycles {
                if state == .jumping {
                    frames.append(PetPlaybackFrame(state: state, frameIndex: 4, duration: profile.jumpPause))
                } else if state == .waiting {
                    frames.append(PetPlaybackFrame(state: state, frameIndex: 0, duration: profile.waitingPause))
                }
            }
        }
        return Self(frames: frames)
    }

    static func wandering(profile: PetPlaybackProfile) -> Self {
        let left = action(.runningLeft, profile: profile).moving(from: 0, to: -10)
        let stand = PetPlaybackFrame(state: .idle, frameIndex: 0, duration: profile.turnPause, from: -10, to: -10)
        let right = action(.runningRight, profile: profile).moving(from: -10, to: 0)
        return Self(frames: left.frames + [stand] + right.frames)
    }

    private func moving(from: Double, to: Double) -> Self {
        let total = Double(duration)
        var elapsed = 0
        return Self(frames: frames.map { frame in
            let start = from + (to - from) * Double(elapsed) / total
            elapsed += frame.duration
            return PetPlaybackFrame(state: frame.state, frameIndex: frame.frameIndex, duration: frame.duration,
                                    from: start, to: from + (to - from) * Double(elapsed) / total)
        })
    }
}

struct PetPlaybackCursor {
    let timeline: PetPlaybackTimeline
    private var index = 0
    private var elapsed = 0
    var isFinished: Bool { index == timeline.frames.count }
    private var frame: PetPlaybackFrame { timeline.frames[min(index, timeline.frames.count - 1)] }
    var state: PetState { frame.state }
    var frameIndex: Int { frame.frameIndex }
    var offset: Double {
        isFinished ? frame.to : frame.from + (frame.to - frame.from) * Double(elapsed) / Double(frame.duration)
    }

    /// Consume only this timeline and return any time left at its exact end.
    /// Callers decide whether to loop, hold, or start a new scene.
    mutating func advance(by milliseconds: Int) -> Int {
        var remaining = max(0, milliseconds)
        while remaining > 0 && !isFinished {
            let delta = min(remaining, frame.duration - elapsed)
            elapsed += delta
            remaining -= delta
            if elapsed == frame.duration {
                index += 1
                elapsed = 0
            }
        }
        return remaining
    }
}

/// Tasks, finite interactions and pointer drags share one playback cursor.
/// Actual failed tasks hold terminal; finite failed gestures finish normally.
public struct PetAnimationReducer {
    public private(set) var taskState: PetState = .idle
    public var state: PetState { playback.state }
    public var frameIndex: Int { playback.frameIndex }
    public var isPlayingTransient: Bool { transientState != nil }

    private var profile = PetPlaybackProfile()
    private var random: PetPlaybackRandom
    private var playback: PetPlaybackCursor
    private var transientState: PetState?
    private var dragDirection: PetDragDirection?

    public init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        random = PetPlaybackRandom(seed: seed)
        playback = PetPlaybackCursor(timeline: .idle(dwell: random.next(3_000...6_000)))
    }

    mutating func configure(profile: PetPlaybackProfile) {
        self.profile = profile
        stop()
    }

    public mutating func setTaskState(_ state: PetState, preservingTransient: Bool = false) {
        taskState = state
        if dragDirection != nil || (preservingTransient && transientState != nil) { return }
        transientState = nil
        restartTask()
    }

    public mutating func playTransient(_ state: PetState) {
        guard state == .waving || state == .jumping || state == .failed else { return }
        guard (taskState != .waiting && taskState != .failed) || state == .failed else { return }
        guard dragDirection == nil else { return }
        transientState = state
        playback = PetPlaybackCursor(timeline: .action(state, profile: profile))
    }

    public mutating func beginDrag(direction: PetDragDirection) {
        dragDirection = direction
        transientState = nil
        playback = PetPlaybackCursor(timeline: .cycle(direction == .left ? .runningLeft : .runningRight))
    }

    public mutating func endDrag() {
        guard dragDirection != nil else { return }
        dragDirection = nil
        transientState = nil
        restartTask()
    }

    public mutating func clear() {
        taskState = .idle
        stop()
    }

    public mutating func stop() {
        transientState = nil
        dragDirection = nil
        restartTask()
    }

    private mutating func restartTask() {
        let timeline: PetPlaybackTimeline = taskState == .idle
            ? .idle(dwell: random.next(profile.idleRange)) : .cycle(taskState)
        playback = PetPlaybackCursor(timeline: timeline)
    }

    public mutating func advance(by milliseconds: Int) {
        var remaining = max(0, milliseconds)
        while remaining > 0 {
            remaining = playback.advance(by: remaining)
            guard playback.isFinished else { return }
            if transientState != nil {
                transientState = nil
                restartTask()
            } else if let dragDirection {
                playback = PetPlaybackCursor(timeline: .cycle(dragDirection == .left ? .runningLeft : .runningRight))
            } else if taskState == .failed {
                return
            } else {
                restartTask()
            }
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
