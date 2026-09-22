import Foundation

/// Local personality only: these poses never change task/telemetry state.
/// Each shuffled bag contains every scene, so rare rows do not need rare hooks.
struct PetBehavior {
    private struct Step {
        let state: PetState
        let duration: Int
        var from: Double = 0
        var to: Double = 0
    }
    private static let scenes: [[Step]] = [
        [Step(state: .runningLeft, duration: 1060, to: -10),
         Step(state: .idle, duration: 400, from: -10, to: -10),
         Step(state: .runningRight, duration: 1060, from: -10)],
        [Step(state: .review, duration: 2060), Step(state: .running, duration: 1640)],
        [Step(state: .waiting, duration: 2020), Step(state: .failed, duration: 1220)],
        [Step(state: .jumping, duration: 840), Step(state: .waving, duration: 700),
         Step(state: .idle, duration: 500)]
    ]
    private var random: UInt64
    private var bag: [Int] = []
    private var previousScene: Int?
    private var scene: Int?
    private var stepIndex = 0
    private var elapsed = 0
    private var quietRemaining = 4_000
    private(set) var state: PetState = .idle
    private(set) var offset: Double = 0
    var isPerforming: Bool { scene != nil }

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { random = seed }

    mutating func interrupt(initialDelay: Bool = false) {
        scene = nil
        stepIndex = 0
        elapsed = 0
        state = .idle
        offset = 0
        quietRemaining = initialDelay ? 4_000 : 15_000 + Int(nextRandom() % 15_001)
    }

    mutating func advance(by milliseconds: Int) {
        var remaining = max(0, milliseconds)
        while remaining > 0 {
            guard let scene else {
                let delta = min(remaining, quietRemaining)
                quietRemaining -= delta
                remaining -= delta
                if quietRemaining == 0 { startScene() }
                continue
            }
            let step = Self.scenes[scene][stepIndex]
            let delta = min(remaining, step.duration - elapsed)
            elapsed += delta
            remaining -= delta
            offset = step.from + (step.to - step.from) * Double(elapsed) / Double(step.duration)
            if elapsed == step.duration {
                stepIndex += 1
                elapsed = 0
                if stepIndex == Self.scenes[scene].count {
                    interrupt()
                } else {
                    let next = Self.scenes[scene][stepIndex]
                    state = next.state
                    offset = next.from
                }
            }
        }
    }

    private mutating func startScene() {
        if bag.isEmpty {
            bag = Array(Self.scenes.indices)
            for index in stride(from: bag.count - 1, through: 1, by: -1) {
                bag.swapAt(index, Int(nextRandom() % UInt64(index + 1)))
            }
            if bag.last == previousScene { bag.swapAt(0, bag.count - 1) }
        }
        let selected = bag.removeLast()
        previousScene = selected
        scene = selected
        stepIndex = 0
        elapsed = 0
        state = Self.scenes[selected][0].state
        offset = 0
    }

    private mutating func nextRandom() -> UInt64 {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return random
    }
}
