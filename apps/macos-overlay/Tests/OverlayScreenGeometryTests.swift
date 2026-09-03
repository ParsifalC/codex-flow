import Cocoa

@main
struct OverlayScreenGeometryTests {
    static func main() {
        testScreenGeometry()
        testVisibleHitRegions()
        testSyntheticHoverGate()
        testSingleOwnerGeometrySequencing()
        testDragThenPendingPresentation()
        testRapidPresentationCoalescing()
        print("Overlay runtime regression tests passed")
    }

    private static func testScreenGeometry() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rightUpper = NSRect(x: 1440, y: 220, width: 1728, height: 1117)
        let leftLower = NSRect(x: -1280, y: -300, width: 1280, height: 800)
        let frames = [primary, rightUpper, leftLower]

        let secondaryPanel = NSRect(x: 2680, y: 780, width: 384, height: 490)
        precondition(
            OverlayScreenGeometry.bestVisibleFrame(for: secondaryPanel, among: frames) == rightUpper,
            "secondary panel should resolve to the right/upper display"
        )

        let partial = NSRect(x: -1210, y: -250, width: 76, height: 76)
        precondition(
            OverlayScreenGeometry.bestVisibleFrame(for: partial, among: frames) == leftLower,
            "partially visible bubble should stay on the intersecting display"
        )

        precondition(
            OverlayScreenGeometry.visibleFrame(containing: NSPoint(x: 2200, y: 700), among: frames) == rightUpper,
            "pointer on secondary display should route drag geometry there"
        )

        let clamped = OverlayScreenGeometry.clamp(
            NSPoint(x: 9999, y: -9999),
            windowSize: NSSize(width: 76, height: 76),
            to: rightUpper,
            margin: 8
        )
        precondition(clamped.x == rightUpper.maxX - 76 - 8)
        precondition(clamped.y == rightUpper.minY + 8)

        let canonicalCollapsedX = rightUpper.maxX - 76
        precondition(canonicalCollapsedX == 3092)
        precondition(canonicalCollapsedX + 76 == rightUpper.maxX)
    }

    private static func testVisibleHitRegions() {
        let host = NSRect(x: 0, y: 0, width: 76, height: 76)

        precondition(
            OverlayCompactHitRegion.contains(NSPoint(x: 38, y: 38), in: host, expanded: false, docked: false),
            "center of circular bubble must be interactive"
        )
        precondition(
            !OverlayCompactHitRegion.contains(NSPoint(x: 2, y: 2), in: host, expanded: false, docked: false),
            "transparent circular-host corner must not be interactive"
        )

        precondition(
            OverlayCompactHitRegion.contains(NSPoint(x: 60, y: 38), in: host, expanded: false, docked: true),
            "visible dock pill must be interactive"
        )
        precondition(
            !OverlayCompactHitRegion.contains(NSPoint(x: 12, y: 38), in: host, expanded: false, docked: true),
            "transparent area left of the dock pill must not untuck it"
        )

        precondition(
            OverlayCompactHitRegion.contains(NSPoint(x: 2, y: 2), in: host, expanded: true, docked: false),
            "expanded panel uses its full host bounds"
        )
    }

    private static func testSyntheticHoverGate() {
        var gate = OverlayHoverGate(rearmDistance: 6)
        gate.suppress(at: NSPoint(x: 100, y: 100))

        precondition(!gate.allowsHover(at: NSPoint(x: 100, y: 100)), "synthetic enter at the same pointer location must be ignored")
        precondition(!gate.allowsHover(at: NSPoint(x: 103, y: 102)), "micro pointer jitter must not rearm hover")
        precondition(gate.allowsHover(at: NSPoint(x: 107, y: 100)), "real pointer movement must rearm hover")
        precondition(gate.allowsHover(at: NSPoint(x: 107, y: 100)), "hover remains armed after genuine movement")
    }

    private static func testSingleOwnerGeometrySequencing() {
        var runtime = OverlayRuntimeState()

        precondition(runtime.requestPresentationGeometry(), "collapse resize should acquire geometry ownership")
        precondition(runtime.activeGeometry == .presentation)
        precondition(!runtime.requestPresentationGeometry(), "a second presentation must be queued, never run concurrently")
        precondition(runtime.pendingPresentationUpdate)

        precondition(runtime.completeGeometry(), "queued presentation should acquire ownership after the first finishes")
        precondition(runtime.activeGeometry == .presentation)
        precondition(!runtime.pendingPresentationUpdate)
        precondition(!runtime.beginSnapGeometry(), "snap cannot steal geometry from the active presentation")

        precondition(!runtime.completeGeometry(), "no further presentation is pending")
        precondition(runtime.activeGeometry == nil)
    }

    private static func testDragThenPendingPresentation() {
        var runtime = OverlayRuntimeState()

        precondition(runtime.beginPointerInteraction(), "drag should start while geometry is idle")
        precondition(runtime.pointerInteractionActive)
        precondition(!runtime.requestPresentationGeometry(), "resize requested during drag must be deferred")
        precondition(runtime.pendingPresentationUpdate)

        runtime.endPointerInteraction()
        precondition(!runtime.pointerInteractionActive, "mouse-up must release interaction independently of any animation completion")
        precondition(runtime.beginSnapGeometry(), "snap should acquire geometry immediately after pointer release")
        precondition(runtime.activeGeometry == .snap)

        precondition(runtime.completeGeometry(), "deferred presentation should run after snap finishes")
        precondition(runtime.activeGeometry == .presentation)
        precondition(!runtime.pointerInteractionActive, "superseding snap must never resurrect a stuck drag flag")
        precondition(!runtime.completeGeometry())
        precondition(runtime.activeGeometry == nil)
    }

    private static func testRapidPresentationCoalescing() {
        var runtime = OverlayRuntimeState()

        precondition(runtime.requestPresentationGeometry()) // collapse
        precondition(!runtime.requestPresentationGeometry()) // expand
        precondition(!runtime.requestPresentationGeometry()) // collapse again
        precondition(runtime.pendingPresentationUpdate, "rapid updates coalesce to one replay")

        precondition(runtime.completeGeometry(), "one replay should remain after the active transition")
        precondition(runtime.activeGeometry == .presentation)
        precondition(!runtime.pendingPresentationUpdate)
        precondition(!runtime.completeGeometry(), "coalescing must not create an animation train")
    }
}
