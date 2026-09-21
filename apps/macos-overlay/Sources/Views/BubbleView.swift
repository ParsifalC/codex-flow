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
        .frame(width: OverlayCompactLayout.hostSize.width, height: OverlayCompactLayout.hostSize.height)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.isDocked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("FlowPilot")
        .accessibilityValue(statusText)
        .accessibilityHint(L("Open task details", "打开任务详情"))
        .help("FlowPilot · " + statusText)
    }

    private var tile: some View {
        HStack(spacing: state.isDocked ? 3 : 8) {
            ResultGlow(isUnread: state.hasUnreadResult)
                .frame(width: 24, height: 28)
            if !state.isDocked {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.hasUnreadResult ? L("New result", "新结果") : (state.latestRun == nil ? L("Waiting", "等待结果") : L("Done", "已完成")))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(OverlayTheme.primary)
                    if let run = state.latestRun {
                        Text(run.totalTokens > 0 ? run.formattedTotalTokens : "—")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(OverlayTheme.secondary)
                    }
                }
                .lineLimit(1)
                .frame(width: 60, alignment: .leading)
            }
        }
        .frame(width: state.isDocked ? OverlayCompactLayout.dockedSize.width : OverlayCompactLayout.tileSize.width,
               height: OverlayCompactLayout.tileSize.height)
        .background {
            if reduceTransparency {
                Color(red: 0.08, green: 0.09, blue: 0.12)
            } else {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                LinearGradient(colors: [Color(red: 0.094, green: 0.106, blue: 0.133).opacity(0.86), Color(red: 0.063, green: 0.071, blue: 0.094).opacity(0.90)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.white.opacity(isHovered ? 0.045 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: OverlayCompactLayout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OverlayCompactLayout.cornerRadius, style: .continuous)
                .strokeBorder(isHovered ? OverlayTheme.accent.opacity(0.35) : Color.white.opacity(0.09), lineWidth: 0.8)
        }
        .overlay(alignment: .bottomTrailing) {
            if updateService.hasUpdateBadge {
                Circle()
                    .fill(updateService.isRestartRequired ? OverlayTheme.warning : OverlayTheme.accent)
                    .frame(width: 4, height: 4)
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: OverlayCompactLayout.cornerRadius, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var statusText: String {
        var text = state.hasUnreadResult ? L("New result", "新结果") : (state.latestRun == nil ? L("Waiting for a result", "等待结果") : L("Latest turn completed", "最近轮次已完成"))
        if let run = state.latestRun {
            text += " · " + (run.totalTokens > 0 ? "Tokens: " + run.formattedTotalTokens : L("Tokens unavailable", "Token 消耗未记录"))
        }
        if updateService.hasUpdateBadge {
            text += " · " + (updateService.isRestartRequired ? L("Restart required", "需要重启") : L("Update available", "发现新版本"))
        }
        return text
    }
}

/// A soft breathing light replaces the static app glyph in both compact states.
private struct ResultGlow: View {
    let isUnread: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                glow(expanded: false)
            } else {
                Color.clear.phaseAnimator([false, true]) { _, expanded in
                    glow(expanded: expanded)
                } animation: { _ in
                    .easeInOut(duration: isUnread ? 1.4 : 2.2)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func glow(expanded: Bool) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [OverlayTheme.accent.opacity(0.55), OverlayTheme.accent.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 12))
                .frame(width: 24, height: 24)
                .scaleEffect(expanded ? 1 : 0.72)
            Circle()
                .strokeBorder(OverlayTheme.accent.opacity(expanded ? 0.12 : 0.50), lineWidth: 0.8)
                .frame(width: 20, height: 20)
                .scaleEffect(expanded ? 1.08 : 0.65)
            Circle()
                .fill(OverlayTheme.accent)
                .frame(width: 6, height: 6)
                .scaleEffect(expanded ? 1.12 : 0.86)
                .shadow(color: OverlayTheme.accent.opacity(0.65), radius: expanded ? 5 : 2)
        }
        .opacity(isUnread ? 1 : 0.65)
    }
}
