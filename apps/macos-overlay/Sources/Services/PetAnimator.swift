import Combine
import Foundation

/// Owns the reducer and its visible compact-view timer. The view calls
/// setVisibility as it appears, expands, hides, or receives a reduce-motion
/// environment change; no timer is kept alive for an expanded/hidden pet.
public final class PetAnimator: ObservableObject {
    @Published public private(set) var state: PetState = .idle
    @Published public private(set) var frameIndex: Int = 0

    @Published public private(set) var horizontalOffset: Double = 0
    public private(set) var isPlayingAutonomously = false
    private var behavior: PetBehavior
    private var usingBehavior = false
    private var autonomyEnabled = false
    private var pointerHeld = false
    private var dragging = false
    private var visibleMilliseconds = 0
    private var lastHoverMilliseconds = -8_000
    private var reducer = PetAnimationReducer()
    private var timer: Timer?
    private var lastTick = Date()
    private var visible = false
    private var expanded = false
    private var reduceMotion = false

    public init(behaviorSeed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        behavior = PetBehavior(seed: behaviorSeed)
        reducer = PetAnimationReducer()
    }

    /// Called only after a resource has been validated and loaded. Unknown IDs
    /// receive the generic profile; changing pets clears old finite gestures.
    public func configure(resourceID: String) {
        let profile = PetPlaybackProfile(resourceID: resourceID)
        reducer.configure(profile: profile)
        behavior.configure(profile: profile)
        pointerHeld = false
        dragging = false
        lastHoverMilliseconds = visibleMilliseconds - 8_000
        usingBehavior = false
        isPlayingAutonomously = false
        publish()
    }

    public func setAutonomyEnabled(_ enabled: Bool) {
        autonomyEnabled = enabled
        interruptBehavior(initialDelay: enabled)
        publish()
    }

    public func beginPointerInteraction() {
        pointerHeld = true
        interruptBehavior()
        publish()
    }

    public func endPointerInteraction() {
        pointerHeld = false
        interruptBehavior()
        publish()
    }

    public func playHover() {
        guard visibleMilliseconds - lastHoverMilliseconds >= 8_000 else { return }
        lastHoverMilliseconds = visibleMilliseconds
        playTransient(.waving)
    }

    private func interruptBehavior(initialDelay: Bool = false) {
        behavior.interrupt(initialDelay: initialDelay)
        usingBehavior = false
        isPlayingAutonomously = false
        horizontalOffset = 0
    }

    deinit {
        stop()
    }

    public var timerIsRunning: Bool { timer != nil }

    public func setVisibility(visible: Bool, expanded: Bool, reduceMotion: Bool) {
        let wasActive = self.visible && !self.expanded && !self.reduceMotion
        self.visible = visible
        self.expanded = expanded
        self.reduceMotion = reduceMotion
        if wasActive && (!visible || expanded || reduceMotion) {
            interruptBehavior()
        }
        if reduceMotion {
            timer?.invalidate()
            timer = nil
            reducer.stop()
            publish()
        } else if visible && !expanded {
            startTimerIfNeeded()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    public func stop() {
        visible = false
        interruptBehavior()
        timer?.invalidate()
        timer = nil
        reducer.stop()
        publish()
    }

    public func setTaskState(_ state: PetState, preservingTransient: Bool = false) {
        interruptBehavior()
        reducer.setTaskState(state, preservingTransient: preservingTransient)
        publish()
    }

    public func playCelebration() {
        interruptBehavior()
        reducer.playTransient(.jumping, repetitions: 3)
        publish()
    }

    public func playTransient(_ state: PetState) {
        interruptBehavior()
        reducer.playTransient(state)
        publish()
    }

    public func beginDrag(direction: PetDragDirection) {
        dragging = true
        interruptBehavior()
        reducer.beginDrag(direction: direction)
        publish()
    }

    public func endDrag() {
        dragging = false
        interruptBehavior()
        reducer.endDrag()
        publish()
    }

    public func clear() {
        interruptBehavior()
        reducer.clear()
        publish()
    }

    /// Deterministic advancement hook for tests and any future event-driven
    /// playback. Timer ticks use the same reducer path.
    public func advance(by milliseconds: Int) {
        guard visible && !expanded && !reduceMotion else { return }
        var remaining = max(0, milliseconds)
        while remaining > 0 {
            let delta = min(remaining, 20)
            remaining -= delta
            visibleMilliseconds += delta
            reducer.advance(by: delta)
            let autonomous = autonomyEnabled && reducer.taskState == .idle
                && !pointerHeld && !dragging && !reducer.isPlayingTransient
            usingBehavior = autonomous
            if autonomous {
                behavior.advance(by: delta)
                isPlayingAutonomously = behavior.isPerforming
            } else {
                isPlayingAutonomously = false
            }
        }
        publish()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, visible, !expanded, !reduceMotion else { return }
        lastTick = Date()
        let next = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        guard visible, !expanded, !reduceMotion else {
            timer?.invalidate()
            timer = nil
            return
        }
        let now = Date()
        let elapsed = max(0, Int(now.timeIntervalSince(lastTick) * 1000))
        lastTick = now
        advance(by: min(elapsed, 250))
    }

    private func publish() {
        state = usingBehavior ? behavior.state : reducer.state
        frameIndex = usingBehavior ? behavior.frameIndex : reducer.frameIndex
        horizontalOffset = isPlayingAutonomously ? behavior.offset : 0
    }
}
