import Foundation

/// Autonomous scenes use the same frame cursor as interactions. Every shuffled
/// bag contains seven independent intentions, reaching all nine atlas rows.
struct PetBehavior {
    private enum Scene: CaseIterable {
        case wave, jump, wait, fail, review, frontRun, wander
        func timeline(profile: PetPlaybackProfile) -> PetPlaybackTimeline {
            switch self {
            case .wave: return .action(.waving, profile: profile)
            case .jump: return .action(.jumping, profile: profile)
            case .wait: return .action(.waiting, profile: profile)
            case .fail: return .action(.failed, profile: profile)
            case .review: return .action(.review, profile: profile)
            case .frontRun: return .action(.running, profile: profile)
            case .wander: return .wandering(profile: profile)
            }
        }
    }
    private var random: PetPlaybackRandom
    private var profile: PetPlaybackProfile
    private var bag: [Scene] = []
    private var previousScene: Scene?
    private var scene: Scene?
    private var playback: PetPlaybackCursor
    var state: PetState { playback.state }
    var frameIndex: Int { playback.frameIndex }
    var offset: Double { playback.offset }
    var isPerforming: Bool { scene != nil }

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max), profile: PetPlaybackProfile = PetPlaybackProfile()) {
        random = PetPlaybackRandom(seed: seed)
        self.profile = profile
        // The first complete idle cycle and neutral dwell total 4.1 seconds.
        playback = PetPlaybackCursor(timeline: .idle(dwell: 3_000))
    }

    mutating func configure(profile: PetPlaybackProfile) {
        self.profile = profile
        bag = []
        previousScene = nil
        interrupt(initialDelay: true)
    }

    mutating func interrupt(initialDelay: Bool = false) {
        scene = nil
        playback = initialDelay
            ? PetPlaybackCursor(timeline: .idle(dwell: 3_000)) : quietPlayback()
    }

    mutating func advance(by milliseconds: Int) {
        var remaining = max(0, milliseconds)
        while remaining > 0 {
            remaining = playback.advance(by: remaining)
            guard playback.isFinished else { return }
            if scene != nil {
                scene = nil
                playback = quietPlayback()
            } else {
                startScene()
            }
        }
    }

    /// Partition the chosen quiet interval into whole idle cycles and 3–6s
    /// neutral rests. Fit the last rest in advance instead of cutting a cycle
    /// short when an unrelated scene deadline expires.
    private mutating func quietPlayback() -> PetPlaybackCursor {
        let quietDuration = random.next(profile.quietRange)
        let idle = PetPlaybackTimeline.cycle(.idle)
        let minimum = idle.duration + profile.idleRange.lowerBound
        let maximum = idle.duration + profile.idleRange.upperBound
        var choices: [(Int, ClosedRange<Int>)] = []
        for count in 1...(quietDuration / minimum) {
            let low = max(profile.idleRange.lowerBound, quietDuration - count * maximum)
            let high = min(profile.idleRange.upperBound, quietDuration - count * minimum)
            if low <= high { choices.append((count, low...high)) }
        }
        let (count, firstRestRange) = choices[random.next(0...(choices.count - 1))]
        let firstRest = random.next(firstRestRange)
        var remaining = quietDuration - firstRest
        var frames = [PetPlaybackFrame(state: .idle, frameIndex: 0, duration: firstRest)]
        for cyclesLeft in stride(from: count, through: 1, by: -1) {
            let low = max(minimum, remaining - (cyclesLeft - 1) * maximum)
            let high = min(maximum, remaining - (cyclesLeft - 1) * minimum)
            let duration = random.next(low...high)
            frames += idle.frames
            frames.append(PetPlaybackFrame(state: .idle, frameIndex: 0, duration: duration - idle.duration))
            remaining -= duration
        }
        return PetPlaybackCursor(timeline: PetPlaybackTimeline(frames: frames))
    }

    private mutating func startScene() {
        if bag.isEmpty {
            bag = Scene.allCases
            for index in stride(from: bag.count - 1, through: 1, by: -1) {
                bag.swapAt(index, random.next(0...index))
            }
            if bag.last == previousScene { bag.swapAt(0, bag.count - 1) }
        }
        let selected = bag.removeLast()
        previousScene = selected
        scene = selected
        playback = PetPlaybackCursor(timeline: selected.timeline(profile: profile))
    }
}
