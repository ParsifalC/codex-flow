import Cocoa

/// Final guardrail for the collapsed overlay's horizontal position.
///
/// The bubble and the tucked pill both live inside the same 76pt transparent
/// host window. The circle already has its own internal safe margin, so moving
/// that host another 8pt left when untucking only creates a second horizontal
/// target. AppKit tracking events can then alternate tuck/untuck and visibly
/// bounce the panel between those two X coordinates.
///
/// While the user is not actively dragging, a collapsed overlay therefore has
/// exactly one horizontal invariant: the host window's right edge is the
/// current display's right edge. Docking becomes a visual state change, not a
/// second window position. Vertical position is intentionally left untouched.
extension OverlayWindowController {
    public func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow,
              movedWindow === window,
              !state.isExpanded,
              !isInteractingOrDragging else { return }

        let frames = NSScreen.screens.map { $0.visibleFrame }
        guard let visible = OverlayScreenGeometry.bestVisibleFrame(
            for: movedWindow.frame,
            among: frames
        ) ?? NSScreen.main?.visibleFrame else { return }

        let canonicalX = visible.maxX - movedWindow.frame.width
        guard abs(movedWindow.frame.origin.x - canonicalX) > 0.5 else { return }

        var origin = movedWindow.frame.origin
        origin.x = canonicalX
        movedWindow.setFrameOrigin(origin)
    }
}
