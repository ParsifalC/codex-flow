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

/// One geometry contract for the SwiftUI tile, window host and pointer filtering.
enum OverlayCompactLayout {
    static let hostSize = NSSize(width: 128, height: 64)
    static let petHostSize = NSSize(width: 128, height: 136)
    static let petSpriteSize = NSSize(width: 96, height: 104)
    static let petContentSize = NSSize(width: 96, height: 122)
    static let tileSize = NSSize(width: 112, height: 48)
    static let dockedSize = NSSize(width: 36, height: 48)
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 8
}

/// Filters the rectangular compact NSHostingView down to what the user can
/// actually see. This prevents the transparent host from behaving as a hover
/// target after the compact view changes shape.
enum OverlayCompactHitRegion {
    static func contains(
        _ point: NSPoint,
        in hostBounds: NSRect,
        expanded: Bool,
        docked: Bool,
        pet: Bool = false
    ) -> Bool {
        guard hostBounds.contains(point) else { return false }
        if expanded { return true }
        if pet {
            let size = OverlayCompactLayout.petContentSize
            let content = NSRect(x: hostBounds.midX - size.width / 2,
                                 y: hostBounds.midY - size.height / 2,
                                 width: size.width, height: size.height)
            // The sprite wanders at most10points; keep the stationary caption
            // and moved sprite clickable without claiming transparent corners.
            let sprite = NSRect(x: content.minX - 10, y: content.maxY - OverlayCompactLayout.petSpriteSize.height,
                                width: size.width + 20, height: OverlayCompactLayout.petSpriteSize.height)
            return content.contains(point) || sprite.contains(point)
        }

        if docked {
            let pillSize = OverlayCompactLayout.dockedSize
            let pillRect = NSRect(
                x: hostBounds.maxX - pillSize.width,
                y: hostBounds.midY - pillSize.height / 2,
                width: pillSize.width,
                height: pillSize.height
            )
            return NSBezierPath(roundedRect: pillRect, xRadius: OverlayCompactLayout.cornerRadius, yRadius: OverlayCompactLayout.cornerRadius).contains(point)
        }

        let rect = hostBounds.insetBy(dx: OverlayCompactLayout.padding, dy: OverlayCompactLayout.padding)
        return NSBezierPath(roundedRect: rect, xRadius: OverlayCompactLayout.cornerRadius, yRadius: OverlayCompactLayout.cornerRadius).contains(point)
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
