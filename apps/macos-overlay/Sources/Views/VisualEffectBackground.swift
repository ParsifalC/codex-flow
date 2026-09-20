import SwiftUI
import AppKit

public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material = .hudWindow
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    public init(material: NSVisualEffectView.Material = .hudWindow, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        update(view)
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        update(nsView)
    }

    private func update(_ view: NSVisualEffectView) {
        view.wantsLayer = true
        view.state = .active
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            view.material = .contentBackground
            view.blendingMode = .withinWindow
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            view.material = material
            view.blendingMode = blendingMode
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
