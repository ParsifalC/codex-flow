import Foundation

@main struct PetBehaviorTests {
    static func main() {
        var behavior = PetBehavior(seed: 42)
        var seen: Set<PetState> = [.idle]
        for _ in 0..<18_000 {
            behavior.advance(by: 20)
            seen.insert(behavior.state)
            precondition(abs(behavior.offset) <= 10.001, "Local wandering must stay bounded")
            if behavior.state == .idle && !behavior.isPerforming { precondition(behavior.offset == 0) }
        }
        precondition(seen == Set(PetState.allCases), "Every row must occur without input or task events")
        behavior.interrupt()
        precondition(behavior.state == .idle && behavior.offset == 0)
        behavior.advance(by: 7_999)
        precondition(!behavior.isPerforming, "Quiet intervals must last at least 8 seconds")

        let unattended = PetAnimator(behaviorSeed: 42)
        unattended.setAutonomyEnabled(true)
        unattended.setVisibility(visible: true, expanded: false, reduceMotion: false)
        var rendered: Set<PetState> = []
        for _ in 0..<18_000 {
            unattended.advance(by: 20)
            rendered.insert(unattended.state)
            precondition(abs(unattended.horizontalOffset) <= 10.001)
        }
        precondition(rendered == Set(PetState.allCases), "The actual animator must render all nine rows, not just schedule them")
        unattended.stop()

        let animator = PetAnimator(behaviorSeed: 42)
        animator.setAutonomyEnabled(true)
        animator.setVisibility(visible: true, expanded: false, reduceMotion: false)
        animator.advance(by: 2_500)
        precondition(animator.isPlayingAutonomously)
        animator.setTaskState(.running)
        animator.advance(by: 40_000)
        precondition(animator.state == .running && animator.horizontalOffset == 0)
        animator.setTaskState(.idle)
        animator.beginPointerInteraction()
        animator.advance(by: 40_000)
        precondition(!animator.isPlayingAutonomously && animator.horizontalOffset == 0)
        animator.beginDrag(direction: .left)
        animator.advance(by: 1_000)
        precondition(animator.state == .runningLeft)
        animator.endDrag()
        animator.endPointerInteraction()
        animator.playHover()
        animator.advance(by: 200)
        let frame = animator.frameIndex
        animator.playHover()
        precondition(animator.frameIndex == frame, "Repeated hover must not reset the wave")
        animator.setVisibility(visible: false, expanded: false, reduceMotion: false)
        let hiddenState = animator.state
        animator.advance(by: 60_000)
        precondition(animator.state == hiddenState && !animator.timerIsRunning)
        animator.setVisibility(visible: true, expanded: true, reduceMotion: false)
        animator.advance(by: 60_000)
        precondition(!animator.isPlayingAutonomously && !animator.timerIsRunning)
        animator.setVisibility(visible: true, expanded: false, reduceMotion: true)
        animator.advance(by: 60_000)
        precondition(animator.horizontalOffset == 0 && animator.frameIndex == 0 && !animator.timerIsRunning)
        animator.stop()
        print("Autonomous scenes cover all nine rows; interruption, bounds and visibility passed")
    }
}
