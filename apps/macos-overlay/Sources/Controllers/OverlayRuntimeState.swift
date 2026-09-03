import Cocoa

enum OverlayGeometryActivity: Equatable {
    case presentation
    case snap
}

/// Small, deterministic state machine for the overlay's interaction/geometry
/// lifecycle. It deliberately knows nothing about NSWindow animation APIs.
///
/// Invariants:
/// - only one geometry activity may own the window at a time;
/// - pointer interaction is independent of animation completion;
/// - presentation updates requested during drag/animation are coalesced and
///   replayed once the current owner releases the window.
struct OverlayRuntimeState {
    private(set) var activeGeometry: OverlayGeometryActivity?
    private(set) var pointerInteractionActive = false
    private(set) var pendingPresentationUpdate = false

    var isGeometryTransitioning: Bool { activeGeometry != nil }

    mutating func beginPointerInteraction() -> Bool {
        guard activeGeometry == nil, !pointerInteractionActive else { return false }
        pointerInteractionActive = true
        return true
    }

    mutating func endPointerInteraction() {
        pointerInteractionActive = false
    }

    /// Returns true when the caller owns the geometry immediately and should
    /// start the presentation transition now. Otherwise the request is coalesced.
    mutating func requestPresentationGeometry() -> Bool {
        guard activeGeometry == nil, !pointerInteractionActive else {
            pendingPresentationUpdate = true
            return false
        }
        activeGeometry = .presentation
        return true
    }

    /// Snap is only valid after the pointer has been released. A snap is never
    /// queued behind another geometry owner because a drag cannot begin while
    /// geometry is transitioning.
    mutating func beginSnapGeometry() -> Bool {
        guard activeGeometry == nil, !pointerInteractionActive else { return false }
        activeGeometry = .snap
        return true
    }

    /// Releases the current geometry owner. Returns true when a coalesced
    /// presentation update has now acquired ownership and should be run next.
    mutating func completeGeometry() -> Bool {
        activeGeometry = nil
        return claimPendingPresentationIfIdle()
    }

    /// Used after a pointer interaction ends without a snap.
    mutating func claimPendingPresentationIfIdle() -> Bool {
        guard pendingPresentationUpdate,
              activeGeometry == nil,
              !pointerInteractionActive else { return false }
        pendingPresentationUpdate = false
        activeGeometry = .presentation
        return true
    }
}

/// Filters the rectangular 76x76 NSHostingView down to what the user can
/// actually see. This prevents the transparent host from behaving as a hover
/// target after the compact view changes shape.
enum OverlayCompactHitRegion {
    static func contains(
        _ point: NSPoint,
        in hostBounds: NSRect,
        expanded: Bool,
        docked: Bool
    ) -> Bool {
        guard hostBounds.contains(point) else { return false }
        if expanded { return true }

        if docked {
            let pillSize = NSSize(width: 44, height: 56)
            let pillRect = NSRect(
                x: hostBounds.maxX - pillSize.width,
                y: hostBounds.midY - pillSize.height / 2,
                width: pillSize.width,
                height: pillSize.height
            )
            return pillRect.contains(point)
        }

        let center = NSPoint(x: hostBounds.midX, y: hostBounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius: CGFloat = 31 // 58pt circle + a small allowance for its glow.
        return dx * dx + dy * dy <= radius * radius
    }
}

/// Synthetic AppKit tracking events may be emitted when a window resizes under
/// a stationary pointer. Require real pointer travel before hover behavior is
/// re-armed after a programmatic compacting/snap operation.
struct OverlayHoverGate {
    private(set) var suppressedAt: NSPoint?
    let rearmDistance: CGFloat

    init(rearmDistance: CGFloat = 6) {
        self.rearmDistance = rearmDistance
    }

    mutating func suppress(at point: NSPoint) {
        suppressedAt = point
    }

    mutating func allowsHover(at point: NSPoint) -> Bool {
        guard let anchor = suppressedAt else { return true }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard dx * dx + dy * dy >= rearmDistance * rearmDistance else { return false }
        suppressedAt = nil
        return true
    }
}
