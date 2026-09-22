import AppKit
import SwiftUI

public struct PetView: View {
    @ObservedObject private var state: OverlayState
    @ObservedObject private var animator: PetAnimator
    private let reduceMotion: Bool

    public init(state: OverlayState, animator: PetAnimator, reduceMotion: Bool) {
        self.state = state
        self.animator = animator
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        Group {
            if let resource = state.petResource,
               let frame = resource.atlas.frameImage(for: animator.state, frame: animator.frameIndex) {
                Image(nsImage: NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)))
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: OverlayCompactLayout.petSpriteSize.width, height: OverlayCompactLayout.petSpriteSize.height)
        .offset(x: animator.horizontalOffset)
        .accessibilityHidden(true)
        .onAppear {
            state.refreshPetVisibility(reduceMotion: reduceMotion)
        }
        .onDisappear {
            animator.stop()
        }
        .onChange(of: state.isExpanded) { _, _ in
            state.refreshPetVisibility(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, reduced in
            state.refreshPetVisibility(reduceMotion: reduced)
        }
    }
}
