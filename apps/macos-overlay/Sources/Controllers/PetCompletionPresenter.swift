import AppKit
import Combine
import SwiftUI

/// A child panel lets the reminder appear without resizing or moving the pet.
final class PetCompletionPresenter {
    private weak var anchor: NSPanel?
    private let state: OverlayState
    private let panel: NSPanel
    private var subscriptions: Set<AnyCancellable> = []

    init(state: OverlayState, anchor: NSPanel) {
        self.state = state
        self.anchor = anchor
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 112),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PetCompletionBubble(state: state))
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.publisher(for: name, object: anchor)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
        }
    }

    private func refresh() {
        guard let anchor, anchor.isVisible, !state.isExpanded,
              state.petResource != nil, state.petCompletionNotice != nil else {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            return
        }
        guard let screen = anchor.screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = min(max(anchor.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let above = anchor.frame.maxY - 8
        let y = above + size.height <= visible.maxY ? above : anchor.frame.minY - size.height + 8
        panel.setFrameOrigin(NSPoint(x: x, y: min(max(y, visible.minY), visible.maxY - size.height)))
        if panel.parent == nil { anchor.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    deinit {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

private struct PetCompletionBubble: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                if let run = state.petCompletionNotice {
                    state.inspect(run: run)
                    state.expand()
                }
                state.dismissPetCompletionNotice()
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.55, green: 0.91, blue: 0.72))
                        Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(L("Click to view", "点击查看结果"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { state.dismissPetCompletionNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55)).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(L("Dismiss reminder", "收起提醒"))
        }
        .padding(12)
        .foregroundStyle(.white)
        .frame(width: 248, height: 100)
        .background(Color(red: 0.10, green: 0.13, blue: 0.16), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .frame(width: 260, height: 112)
    }

    private var title: String {
        if state.petUnreadCount > 1 {
            return L("\(state.petUnreadCount) tasks completed", "\(state.petUnreadCount) 项任务已完成")
        }
        guard !state.isPrivacyMode, let run = state.petCompletionNotice, !run.projectName.isEmpty else {
            return L("Task completed", "任务已完成")
        }
        return L("Done · ", "已完成 · ") + run.projectName
    }

    private var detail: String {
        guard !state.isPrivacyMode else { return L("Your result is ready", "结果已准备好") }
        return state.petCompletionNotice?.publishedGoal ?? L("Your result is ready", "结果已准备好")
    }
}
