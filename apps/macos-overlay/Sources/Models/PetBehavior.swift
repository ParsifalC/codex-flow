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
        // Start with two complete default animation cycles.
        playback = Self.defaultPlayback(cycles: 2)
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
            ? Self.defaultPlayback(cycles: 2) : quietPlayback()
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

    /// Fill the interval with complete default animation loops, with no added holds.
    private mutating func quietPlayback() -> PetPlaybackCursor {
        let duration = PetPlaybackTimeline.cycle(.idle).duration
        let minimumCycles = (profile.quietRange.lowerBound + duration - 1) / duration
        let maximumCycles = profile.quietRange.upperBound / duration
        return Self.defaultPlayback(cycles: random.next(minimumCycles...maximumCycles))
    }

    private static func defaultPlayback(cycles: Int) -> PetPlaybackCursor {
        let idle = PetPlaybackTimeline.cycle(.idle)
        return PetPlaybackCursor(timeline: PetPlaybackTimeline(
            frames: Array(repeating: idle.frames, count: cycles).flatMap { $0 }
        ))
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
