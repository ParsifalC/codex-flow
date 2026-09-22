import Foundation

@main
struct PetPlaybackTests {
    static func main() {
        testNeutralIdleDwell()
        testCompleteHoverAndJumpCycles()
        testNoDirectionalBrake()
        testVariableIdleDwell()
        testProfilesAndAutonomousScenes()
        testPriorityAndProfileReset()
        print("Natural playback frame cycles, neutral dwell and run continuity passed")
    }

    // Catches holding Dasheng's closed-eye last frame or immediately restarting a blink.
    private static func testNeutralIdleDwell() {
        var reducer = PetAnimationReducer()
        reducer.advance(by: 1_100)
        precondition(reducer.frameIndex == 0, "Idle must finish on the neutral first atlas frame")
        for _ in 0..<150 {
            reducer.advance(by: 20)
            precondition(reducer.state == .idle && reducer.frameIndex == 0,
                         "Idle must rest on its first frame for at least three seconds")
        }
        var resumed = false
        for _ in 0..<200 {
            reducer.advance(by: 20)
            if reducer.frameIndex != 0 { resumed = true }
        }
        precondition(resumed, "Idle must eventually play another complete blink")
    }

    // Counts visible visits to the final frame instead of reading repeat-count constants.
    private static func testCompleteHoverAndJumpCycles() {
        for (action, lastFrame) in [(PetState.waving, 3), (.jumping, 4)] {
            var reducer = PetAnimationReducer()
            reducer.setTaskState(.running)
            reducer.playTransient(action)
            var visits = 0
            var previous = -1
            var elapsed = 0
            while reducer.state == action && elapsed < 5_000 {
                if reducer.frameIndex == lastFrame && previous != lastFrame { visits += 1 }
                previous = reducer.frameIndex
                reducer.advance(by: 10)
                elapsed += 10
            }
            precondition(visits == 2, "A generic hover/jump must render two complete cycles")
            precondition(reducer.state == .running && reducer.frameIndex == 0,
                         "A finished transient must restore the real task at its first frame")
        }
    }

    private static func testNoDirectionalBrake() {
        var reducer = PetAnimationReducer()
        reducer.beginDrag(direction: .right)
        reducer.advance(by: 840)
        precondition(reducer.frameIndex == 7)
        reducer.advance(by: 119)
        precondition(reducer.frameIndex == 7)
        reducer.advance(by: 1)
        precondition(reducer.frameIndex == 0, "Directional loops must not brake on their last frame")
    }
    private struct Sample {
        let state: PetState
        let frame: Int
        let offset: Double
    }

    private static func visits(_ samples: [Sample], state: PetState, frame: Int) -> Int {
        var count = 0
        var previous: Sample?
        for sample in samples {
            if sample.state == state && sample.frame == frame &&
                (previous?.state != state || previous?.frame != frame) { count += 1 }
            previous = sample
        }
        return count
    }

    private static func longestHold(_ samples: [Sample], state: PetState, frame: Int) -> Int {
        var longest = 0
        var duration = 0
        for sample in samples {
            duration = sample.state == state && sample.frame == frame ? duration + 10 : 0
            longest = max(longest, duration)
        }
        return longest
    }

    private static func testVariableIdleDwell() {
        var reducer = PetAnimationReducer(seed: 42)
        var zeroDuration = 0
        var previous = 0
        var rests: [Int] = []
        for _ in 0..<4_000 {
            if reducer.frameIndex == 0 { zeroDuration += 10 }
            if reducer.frameIndex != 0 && previous == 0 {
                if zeroDuration > 280 { rests.append(zeroDuration - 280) }
                zeroDuration = 0
            }
            previous = reducer.frameIndex
            reducer.advance(by: 10)
        }
        precondition(rests.count >= 4 && Set(rests).count > 1, "Idle rests must vary per complete cycle")
        precondition(rests.allSatisfy { $0 >= 3_000 && $0 <= 6_010 }, "Neutral rests must stay within 3–6 seconds")
    }

    // Samples precisely what the view renders. A scene scheduler with the right
    // constants but a looping/early-cut frame reducer cannot pass these checks.
    private static func testProfilesAndAutonomousScenes() {
        let cases: [(String, Int, Int, Int)] = [
            ("dasheng", 2, 4, 2), ("deepseek", 3, 3, 3),
            ("doraemon", 2, 4, 3), ("lulu-capybara-2", 2, 3, 4),
            ("noir-webling", 3, 4, 1), ("unknown-custom", 2, 4, 3)
        ]
        for (id, waves, failedPose, reviewPose) in cases {
            let animator = PetAnimator(behaviorSeed: 42)
            animator.configure(resourceID: id)
            animator.setAutonomyEnabled(true)
            animator.setVisibility(visible: true, expanded: false, reduceMotion: false)
            defer { animator.stop() }
            var rendered = Set<PetState>()
            var scenes = [[Sample]]()
            var active: [Sample] = []
            var quietStart: Int?
            var quietDurations: [Int] = []
            for elapsed in stride(from: 0, through: 360_000, by: 10) {
                if animator.isPlayingAutonomously {
                    if active.isEmpty, let start = quietStart {
                        quietDurations.append(elapsed - start)
                        quietStart = nil
                    }
                    active.append(Sample(state: animator.state, frame: animator.frameIndex, offset: animator.horizontalOffset))
                } else if !active.isEmpty {
                    scenes.append(active)
                    active = []
                    quietStart = elapsed
                    precondition(animator.state == .idle && animator.frameIndex == 0 && animator.horizontalOffset == 0,
                                 "Completed scene must return to neutral origin: \(id)")
                }
                rendered.insert(animator.state)
                precondition(abs(animator.horizontalOffset) <= 10.001)
                animator.advance(by: 10)
            }
            precondition(rendered == Set(PetState.allCases), "Every row must actually render for \(id)")
            precondition(quietDurations.count >= 7 && Set(quietDurations).count > 1)
            precondition(quietDurations.allSatisfy {
                $0 >= (id == "noir-webling" ? 30_000 : 20_000) - 10 && $0 <= 35_010
            }, "Quiet scene intervals must stay in the profile range")
            for samples in scenes {
                let states = Set(samples.map(\.state))
                if states.contains(.runningLeft) {
                    precondition(states == Set([.runningLeft, .idle, .runningRight]))
                    for direction in [PetState.runningLeft, .runningRight] {
                        precondition(visits(samples, state: direction, frame: 7) == 2, "Wandering must run two full cycles per direction")
                        precondition(longestHold(samples, state: direction, frame: 7) <= 120, "No last-frame directional brake")
                    }
                    let stand = samples.filter { $0.state == .idle }
                    precondition(stand.count * 10 >= 600 && stand.allSatisfy { $0.frame == 0 && abs($0.offset + 10) < 0.001 })
                    precondition(abs(samples.last!.offset) < 0.1, "Wandering must return smoothly to the origin")
                    continue
                }
                precondition(states.count == 1, "Ordinary scenes must express one independent intention")
                let action = samples[0].state
                let duration = samples.count * 10
                switch action {
                case .waving:
                    precondition(visits(samples, state: action, frame: 3) == waves)
                    precondition(abs(duration - waves * 700) <= 10)
                case .jumping:
                    precondition(visits(samples, state: action, frame: 4) == 2, "Exactly two completed jumps")
                    precondition(longestHold(samples, state: action, frame: 4) >= 430, "Jump gap must be grounded at source frame 4")
                    precondition(duration >= 1_830 && duration <= 2_200)
                case .failed:
                    for frame in 0..<8 { precondition(visits(samples, state: action, frame: frame) == 1, "Autonomous failed must never loop") }
                    precondition(longestHold(samples, state: action, frame: failedPose) >= 940)
                    precondition(samples.last?.frame == 7, "Failed must finish its original sequence after the middle pose")
                    precondition(longestHold(samples, state: action, frame: 7) >= 230)
                case .waiting:
                    precondition(visits(samples, state: action, frame: 5) == 2)
                    precondition(longestHold(samples, state: action, frame: 0) >= 450)
                    precondition(duration >= 2_320 && duration <= 2_530)
                case .review:
                    precondition(visits(samples, state: action, frame: 5) == 2)
                    precondition(longestHold(samples, state: action, frame: reviewPose) >= 550)
                    precondition(duration >= 2_450 && duration <= 2_800)
                case .running:
                    precondition(visits(samples, state: action, frame: 5) == 3)
                    precondition(abs(duration - 2_460) <= 10)
                default: preconditionFailure("Unexpected standalone scene")
                }
                precondition(samples.last?.frame == (action == .waving ? 3 : action == .jumping ? 4 : action == .failed ? 7 : 5),
                             "A scene must render its complete last frame before returning")
            }

            // Hover and completion take their repetitions from the loaded profile too.
            animator.setAutonomyEnabled(false)
            animator.setTaskState(.running)
            for (action, last, expected) in [(PetState.waving, 3, waves), (.jumping, 4, 2)] {
                animator.playTransient(action)
                var samples: [Sample] = []
                for _ in 0..<500 {
                    guard animator.state == action else { break }
                    samples.append(Sample(state: animator.state, frame: animator.frameIndex, offset: animator.horizontalOffset))
                    animator.advance(by: 10)
                }
                precondition(visits(samples, state: action, frame: last) == expected)
                precondition(animator.state == .running && animator.frameIndex == 0)
            }
        }
    }

    private static func testPriorityAndProfileReset() {
        let animator = PetAnimator(behaviorSeed: 7)
        animator.configure(resourceID: "deepseek")
        animator.setVisibility(visible: true, expanded: false, reduceMotion: false)
        animator.setTaskState(.running)
        animator.playHover()
        animator.advance(by: 900)
        precondition(animator.state == .waving)
        animator.playHover()
        precondition(animator.frameIndex == 1, "Hover cooldown must not reset an active gesture")
        animator.configure(resourceID: "dasheng")
        precondition(animator.state == .running && animator.frameIndex == 0, "Pet switch must clear old gestures and retain real task")
        animator.playTransient(.jumping)
        animator.advance(by: 850)
        animator.setTaskState(.waiting)
        precondition(animator.state == .waiting, "Task priority must immediately interrupt gestures")
        animator.playTransient(.waving)
        precondition(animator.state == .waiting)
        animator.beginDrag(direction: .left)
        animator.setTaskState(.failed)
        precondition(animator.state == .runningLeft)
        animator.endDrag()
        animator.advance(by: 100_000)
        precondition(animator.state == .failed && animator.frameIndex == 7, "Real failure must retain terminal priority")
        animator.setTaskState(.running)
        animator.advance(by: 10_000)
        precondition(animator.state == .running)
        animator.setVisibility(visible: true, expanded: false, reduceMotion: true)
        animator.advance(by: 100_000)
        precondition(animator.frameIndex == 0 && !animator.timerIsRunning)
        animator.stop()
    }

}
