import Combine
import Foundation

/// Owns the reducer and its visible compact-view timer. The view calls
/// setVisibility as it appears, expands, hides, or receives a reduce-motion
/// environment change; no timer is kept alive for an expanded/hidden pet.
public final class PetAnimator: ObservableObject {
    @Published public private(set) var state: PetState = .idle
    @Published public private(set) var frameIndex: Int = 0

    private var reducer = PetAnimationReducer()
    private var timer: Timer?
    private var lastTick = Date()
    private var visible = false
    private var expanded = false
    private var reduceMotion = false

    public init() {}

    deinit {
        stop()
    }

    public var timerIsRunning: Bool { timer != nil }

    public func setVisibility(visible: Bool, expanded: Bool, reduceMotion: Bool) {
        self.visible = visible
        self.expanded = expanded
        self.reduceMotion = reduceMotion
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
        timer?.invalidate()
        timer = nil
        reducer.stop()
        publish()
    }

    public func setTaskState(_ state: PetState) {
        reducer.setTaskState(state)
        publish()
    }

    public func playTransient(_ state: PetState) {
        reducer.playTransient(state)
        publish()
    }

    public func beginDrag(direction: PetDragDirection) {
        reducer.beginDrag(direction: direction)
        publish()
    }

    public func endDrag() {
        reducer.endDrag()
        publish()
    }

    public func clear() {
        reducer.clear()
        publish()
    }

    /// Deterministic advancement hook for tests and any future event-driven
    /// playback. Timer ticks use the same reducer path.
    public func advance(by milliseconds: Int) {
        reducer.advance(by: milliseconds)
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
        reducer.advance(by: elapsed)
        publish()
    }

    private func publish() {
        state = reducer.state
        frameIndex = reducer.frameIndex
    }
}
