import Cocoa

@main
struct OverlayScreenGeometryTests {
    static func main() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rightUpper = NSRect(x: 1440, y: 220, width: 1728, height: 1117)
        let leftLower = NSRect(x: -1280, y: -300, width: 1280, height: 800)
        let frames = [primary, rightUpper, leftLower]

        // Regression: a panel on a secondary display must stay on that display;
        // it must never fall back to the primary display just because AppKit's
        // window.screen is transiently unavailable during an animation.
        let secondaryPanel = NSRect(x: 2680, y: 780, width: 384, height: 490)
        precondition(
            OverlayScreenGeometry.bestVisibleFrame(for: secondaryPanel, among: frames) == rightUpper,
            "secondary panel should resolve to the right/upper display"
        )

        // A partially off-screen frame should prefer the display with the actual
        // overlap rather than an unrelated primary-display fallback.
        let partial = NSRect(x: -1210, y: -250, width: 76, height: 76)
        precondition(
            OverlayScreenGeometry.bestVisibleFrame(for: partial, among: frames) == leftLower,
            "partially visible bubble should stay on the intersecting display"
        )

        // Pointer-driven dragging must resolve against the display under the
        // pointer, so crossing between displays cannot inherit a stale screen.
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

        print("OverlayScreenGeometryTests passed")
    }
}
