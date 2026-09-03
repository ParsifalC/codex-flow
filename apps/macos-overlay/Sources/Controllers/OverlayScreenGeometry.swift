import Cocoa

/// Pure screen-geometry selection used by the overlay window controller.
///
/// `NSWindow.screen` can be temporarily nil or point at a different display while
/// AppKit is animating/resizing a borderless panel. Geometry routing therefore
/// derives the destination display from global coordinates instead.
enum OverlayScreenGeometry {
    static func bestVisibleFrame(for windowFrame: NSRect, among visibleFrames: [NSRect]) -> NSRect? {
        guard !visibleFrames.isEmpty else { return nil }

        let center = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingCenter = visibleFrames.first(where: { $0.contains(center) }) {
            return containingCenter
        }

        var bestIntersectionFrame: NSRect?
        var bestIntersectionArea: CGFloat = 0
        for candidate in visibleFrames {
            let intersection = windowFrame.intersection(candidate)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestIntersectionFrame = candidate
            }
        }
        if let bestIntersectionFrame {
            return bestIntersectionFrame
        }

        return visibleFrames.min {
            distanceSquared(from: center, to: $0) < distanceSquared(from: center, to: $1)
        }
    }

    /// Presentation expand/collapse is anchored at the window's top-trailing
    /// corner. A wide panel may straddle two displays while its top-trailing
    /// anchor still clearly belongs to the display where the compact bubble
    /// lives. Using the panel center here can move the bubble to the neighbor.
    static func presentationVisibleFrame(for windowFrame: NSRect, among visibleFrames: [NSRect]) -> NSRect? {
        guard !visibleFrames.isEmpty else { return nil }
        let anchor = topTrailingAnchor(for: windowFrame)
        return visibleFrame(containing: anchor, among: visibleFrames)
    }

    static func topTrailingAnchor(for frame: NSRect, inset: CGFloat = 1) -> NSPoint {
        NSPoint(
            x: max(frame.minX, frame.maxX - inset),
            y: max(frame.minY, frame.maxY - inset)
        )
    }

    static func visibleFrame(containing point: NSPoint, among visibleFrames: [NSRect]) -> NSRect? {
        guard !visibleFrames.isEmpty else { return nil }
        if let containing = visibleFrames.first(where: { $0.contains(point) }) {
            return containing
        }
        return visibleFrames.min {
            distanceSquared(from: point, to: $0) < distanceSquared(from: point, to: $1)
        }
    }

    static func clamp(_ origin: NSPoint, windowSize: NSSize, to visibleFrame: NSRect, margin: CGFloat = 0) -> NSPoint {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - windowSize.width - margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - windowSize.height - margin
        return NSPoint(
            x: max(minX, min(origin.x, maxX)),
            y: max(minY, min(origin.y, maxY))
        )
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let x = max(rect.minX, min(point.x, rect.maxX))
        let y = max(rect.minY, min(point.y, rect.maxY))
        let dx = point.x - x
        let dy = point.y - y
        return dx * dx + dy * dy
    }
}
