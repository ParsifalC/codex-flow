import SwiftUI
import AppKit

public struct BubbleView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var updateService = FlowPilotUpdateService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    public init(state: OverlayState) { self.state = state }

    public var body: some View {
        HStack(spacing: 0) {
            if state.isDocked && state.dockEdge == .right { Spacer(minLength: 0) }
            tile
            if state.isDocked && state.dockEdge != .right { Spacer(minLength: 0) }
        }
        .frame(width: 166, height: 76)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.isDocked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("FlowPilot")
        .accessibilityValue(statusText)
        .accessibilityHint(L("Open task details", "打开任务详情"))
        .help("FlowPilot · " + statusText)
    }

    private var tile: some View {
        HStack(spacing: state.isDocked ? 3 : 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: state.isDocked ? 17 : 23, weight: .medium))
                .foregroundStyle(.cyan.opacity(0.95))
            if !state.isDocked {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.hasUnreadResult ? L("New result", "新结果") : (state.latestRun == nil ? L("Waiting", "等待结果") : L("Completed", "最近完成")))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    if let run = state.latestRun {
                        Text(run.totalTokens > 0 ? run.formattedTotalTokens + " tokens" : L("Tokens unavailable", "消耗未记录"))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }.lineLimit(1)
            } else {
                Image(systemName: state.dockEdge == .right ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: state.isDocked ? 40 : 148, height: 58)
        .background {
            ZStack {
                if !reduceTransparency { VisualEffectBackground() }
                Color(red: 0.10, green: 0.15, blue: 0.19).opacity(reduceTransparency ? 1 : 0.8)
                LinearGradient(colors: [.cyan.opacity(isHovered ? 0.18 : 0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.32 : 0.17), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Circle().fill(state.hasUnreadResult ? Color.cyan : Color.clear)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(state.hasUnreadResult ? Color(red: 0.10, green: 0.15, blue: 0.19) : .clear, lineWidth: 2))
                .padding(7)
        }
        .overlay(alignment: .bottomTrailing) {
            if updateService.hasUpdateBadge {
                Image(systemName: updateService.isRestartRequired ? "arrow.clockwise" : "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(updateService.isRestartRequired ? .orange : .cyan)
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var statusText: String {
        let task = state.hasUnreadResult ? L("New result", "新结果") : (state.latestRun == nil ? L("Waiting for a result", "等待结果") : L("Latest turn completed", "最近轮次已完成"))
        if updateService.hasUpdateBadge {
            return task + " · " + (updateService.isRestartRequired ? L("Restart required", "需要重启") : L("Update available", "发现新版本"))
        }
        return task
    }

}
