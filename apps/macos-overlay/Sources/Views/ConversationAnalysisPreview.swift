import SwiftUI
import AppKit

public struct ConversationAnalysisPreview: View {
    @ObservedObject public var service: ConversationAnalysisService
    @State private var skillDraft = AnalysisSkillDraftState()
    @State private var originalExpanded = false
    @State private var sourceExpanded = false
    @State private var exportMessage: String?

    public init(service: ConversationAnalysisService) {
        self.service = service
    }

    public var body: some View {
        HStack(spacing: 0) {
            turnList
                .frame(width: 276)
            OverlayDivider(vertical: true)
            detail
        }
        .frame(minWidth: 980, minHeight: 740)
        .foregroundStyle(OverlayTheme.primary)
        .background(Color(red: 0.065, green: 0.075, blue: 0.095))
        .environment(\.colorScheme, .dark)
        .onAppear { service.start() }
        .onReceive(service.$projection) { projection in
            if !projection.privacyMode { skillDraft.load(skill: projection.selectedSkill) }
        }
        .alert(
            L("Export skill", "导出 Skill"),
            isPresented: Binding(
                get: { exportMessage != nil },
                set: { if !$0 { exportMessage = nil } }
            )
        ) {
            Button(L("OK", "好")) { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private var turnList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Conversation turns", "对话轮次"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(service.projection.snapshot.sessionID ?? "—")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(OverlayTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    service.selectLatest()
                } label: {
                    Text(L("Latest", "最新"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(service.projection.selectedTurnID == service.projection.latestTurnID ? OverlayTheme.accent : OverlayTheme.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(OverlayButtonStyle(cornerRadius: 13))
                .disabled(service.projection.latestTurnID == nil)
                .accessibilityLabel(L("Select latest turn", "选择最新轮次"))
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 15)

            OverlayDivider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if service.projection.turns.isEmpty {
                        Text(L("No turns recorded yet.", "还没有记录轮次。"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(OverlayTheme.secondary)
                            .padding(18)
                    }
                    ForEach(service.projection.turns) { turn in
                        turnRow(turn)
                    }
                }
                .padding(.vertical, 9)
            }
        }
        .background(Color.white.opacity(0.018))
    }

    private func turnRow(_ turn: AnalysisTurn) -> some View {
        let selected = turn.turnID == service.projection.selectedTurnID
        return Button {
            service.select(turnID: turn.turnID)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(statusColor(turn.summary.status))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(L("Turn", "轮次") + " \(turn.sequence)")
                            .font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                        Text(shortStatus(turn))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(statusColor(turn.summary.status))
                    }
                    Text(service.projection.privacyMode
                         ? L("Conversation text hidden", "会话文本已隐藏")
                         : (turn.userText.isEmpty ? L("No user text", "没有用户文本") : turn.userText))
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? OverlayTheme.primary : OverlayTheme.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? OverlayTheme.accent.opacity(0.13) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(OverlayButtonStyle(cornerRadius: 9))
        .padding(.horizontal, 8)
        .accessibilityLabel(L("Turn \(turn.sequence)", "第 \(turn.sequence) 轮"))
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header
            OverlayDivider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    sourceMessages
                    if let sourceError = service.projection.sourceError {
                        notice(
                            title: L("Source warning", "来源警告"),
                            text: "\(sourceError.code): \(sourceError.message)",
                            tint: OverlayTheme.warning
                        )
                    }
                    if let error = service.errorMessage {
                        notice(title: L("Preview warning", "预览警告"), text: error, tint: OverlayTheme.warning)
                    }
                    if let error = service.commandErrorMessage {
                        notice(title: L("Action failed", "操作失败"), text: error, tint: OverlayTheme.warning)
                    }
                    requirementCard
                    summaryCard
                    skillCard
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OverlayTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("FlowPilot · " + L("Conversation Analysis Preview", "对话分析预览"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(service.projection.snapshot.enabled
                     ? L("Local snapshot", "本地快照")
                     : L("Analysis disabled", "分析已停用"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(service.projection.snapshot.enabled ? OverlayTheme.muted : OverlayTheme.warning)
            }
            Spacer()
            Button {
                service.setPrivacyMode(!service.projection.privacyMode)
            } label: {
                Image(systemName: service.projection.privacyMode ? "eye.slash.fill" : "eye")
                    .foregroundStyle(service.projection.privacyMode ? OverlayTheme.warning : OverlayTheme.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(OverlayButtonStyle())
            .help(service.projection.privacyMode
                  ? L("Disable privacy mode", "关闭隐私模式")
                  : L("Enable privacy mode", "开启隐私模式"))
            .accessibilityLabel(service.projection.privacyMode
                                ? L("Disable privacy mode", "关闭隐私模式")
                                : L("Enable privacy mode", "开启隐私模式"))
            Button {
                service.reloadNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(OverlayTheme.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(OverlayButtonStyle())
            .help(L("Refresh snapshot", "刷新快照"))
            .accessibilityLabel(L("Refresh snapshot", "刷新快照"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    private var sourceMessages: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let source = service.projection.snapshot.source,
               source.truncated == true || source.status == "partial" {
                Label(
                    L("Source coverage is partial; model context may be truncated.",
                      "来源覆盖不完整；模型上下文可能已截断。"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(OverlayTheme.warning)
            }
            if let source = service.projection.snapshot.source,
               source.status == "complete" && source.truncated != true {
                Text(L("Source coverage complete.", "来源覆盖完整。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(OverlayTheme.muted)
            }
            if let turn = service.projection.selectedTurn {
                DisclosureGroup(
                    isExpanded: $sourceExpanded
                ) {
                    if service.projection.privacyMode {
                        Text(L("Hidden in privacy mode.", "隐私模式下已隐藏。"))
                            .foregroundStyle(OverlayTheme.muted)
                    } else {
                        Text(turn.userText.isEmpty ? L("No user text recorded.", "没有记录用户文本。") : turn.userText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(OverlayTheme.secondary)
                            .textSelection(.enabled)
                    }
                } label: {
                    Label(L("Source user message", "来源用户消息"), systemImage: "quote.opening")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OverlayTheme.secondary)
                }
                .disclosureGroupStyle(OverlayDisclosureStyle())
            }
        }
    }

    private var requirementCard: some View {
        card {
            cardHeading(
                title: L("Requirement", "需求"),
                icon: "scope",
                status: service.projection.selectedTurn?.requirement.status
            )
            if let text = service.projection.requirementText {
                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OverlayTheme.primary)
                    .textSelection(.enabled)
            } else if let state = service.projection.selectedTurn?.requirement {
                Text(jobStateText(state, kind: .requirement))
                    .font(.system(size: 13))
                    .foregroundStyle(OverlayTheme.secondary)
            }
            if let revision = service.projection.selectedTurn?.requirement.revision {
                Text(L("Revision \(revision)", "修订 \(revision)"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(OverlayTheme.muted)
            }
            if !service.projection.privacyMode,
               let caveats = service.projection.selectedTurn?.requirement.caveats,
               !caveats.isEmpty {
                caveatBlock(caveats)
            }
            if let jobID = service.projection.retryJobID(for: .requirement) {
                Button(L("Retry requirement", "重试需求")) {
                    _ = service.retry(kind: .requirement)
                }
                .buttonStyle(OverlayButtonStyle())
                .foregroundStyle(OverlayTheme.accent)
                .font(.system(size: 11.5))
                .help(jobID)
            }
        }
    }

    private var summaryCard: some View {
        card {
            cardHeading(
                title: L("Reply summary", "回复摘要"),
                icon: "text.alignleft",
                status: service.projection.selectedTurn?.summary.status
            )
            if let text = service.projection.summaryText {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(OverlayTheme.primary)
                    .textSelection(.enabled)
            } else if service.projection.currentTurnWaitingForFinal {
                Text(L("Waiting for this turn's reply to finish before generating a summary.",
                       "等待本轮回复结束后生成摘要。"))
                    .font(.system(size: 13))
                    .foregroundStyle(OverlayTheme.secondary)
            } else if service.projection.historicalTurnNeedsAnalysis {
                Text(L("Click Analyze this turn to generate the summary.",
                       "点击“分析此轮”生成摘要。"))
                    .font(.system(size: 13))
                    .foregroundStyle(OverlayTheme.secondary)
            } else if let state = service.projection.selectedTurn?.summary {
                Text(jobStateText(state, kind: .summary))
                    .font(.system(size: 13))
                    .foregroundStyle(OverlayTheme.secondary)
            }
            HStack(spacing: 12) {
                if let turn = service.projection.selectedTurn {
                    let canAnalyze = !service.projection.privacyMode &&
                        turn.originalResult != nil &&
                        turn.summary.status != "succeeded"
                    Button(L("Analyze this turn", "分析此轮")) {
                        _ = service.analyzeSelectedTurn()
                    }
                    .buttonStyle(OverlayButtonStyle())
                    .foregroundStyle(OverlayTheme.accent)
                    .font(.system(size: 11.5))
                    .disabled(!canAnalyze)
                }
                if let jobID = service.projection.retryJobID(for: .summary) {
                    Button(L("Retry summary", "重试摘要")) {
                        _ = service.retry(kind: .summary)
                    }
                    .buttonStyle(OverlayButtonStyle())
                    .foregroundStyle(OverlayTheme.accent)
                    .font(.system(size: 11.5))
                    .help(jobID)
                }
            }
            if let original = service.projection.originalResult {
                DisclosureGroup(isExpanded: $originalExpanded) {
                    Text(original)
                        .font(.system(size: 12.5))
                        .foregroundStyle(OverlayTheme.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label(L("Full original reply", "完整原始回复"), systemImage: "doc.plaintext")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OverlayTheme.secondary)
                }
                .disclosureGroupStyle(OverlayDisclosureStyle())
            }
            if !service.projection.privacyMode,
               let caveats = service.projection.selectedTurn?.summary.caveats,
               !caveats.isEmpty {
                caveatBlock(caveats)
            }
        }
    }

    private var skillCard: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                cardHeading(
                    title: L("Skill draft", "Skill 草稿"),
                    icon: "wand.and.stars",
                    status: service.projection.selectedSkill?.status
                )
                Spacer()
                Button(L("Extract", "提取")) {
                    _ = service.extractSkill()
                }
                .buttonStyle(OverlayButtonStyle())
                .foregroundStyle(OverlayTheme.accent)
                .font(.system(size: 11.5))
                .disabled(!service.projection.canExtractSkill)
            }
            if service.projection.privacyMode {
                Text(L("Hidden in privacy mode.", "隐私模式下已隐藏。"))
                    .font(.system(size: 13))
                    .foregroundStyle(OverlayTheme.muted)
            } else if let skill = service.projection.selectedSkill {
                if let name = skill.name, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                }
                if let description = skill.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(OverlayTheme.secondary)
                }
                if skill.status == "succeeded" {
                    TextEditor(text: $skillDraft.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OverlayTheme.primary)
                        .frame(minHeight: 150)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
                    HStack {
                        if !skill.caveats.isEmpty { caveatBlock(skill.caveats) }
                        Spacer()
                        Button(L("Export SKILL.md", "导出 SKILL.md")) {
                            exportSkill()
                        }
                        .buttonStyle(OverlayButtonStyle())
                        .foregroundStyle(OverlayTheme.accent)
                        .font(.system(size: 11.5))
                        .disabled(!service.projection.canExportSkill || service.projection.privacyMode)
                    }
                } else {
                    Text(jobStateText(skill))
                        .font(.system(size: 13))
                        .foregroundStyle(OverlayTheme.secondary)
                    if !skill.caveats.isEmpty { caveatBlock(skill.caveats) }
                }
                if skill.status == "failed" {
                    Button(L("Retry", "重试")) { _ = service.retry(kind: .skill) }
                        .disabled(service.projection.privacyMode)
                }
                if let error = skill.error, !error.isEmpty {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(OverlayTheme.warning)
                }
            } else {
                Text(L("Extract from the conversation through this turn.",
                       "从会话开始到所选轮次，提炼可复用的技能草稿。"))
                    .font(.system(size: 13))
                    .foregroundStyle(OverlayTheme.secondary)
            }
        }
    }

    private func exportSkill() {
        guard service.projection.canExportSkill, !service.projection.privacyMode else { return }
        let capturedDraft = skillDraft.text
        let capturedJobID = service.projection.selectedSkill?.jobID
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SKILL.md"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if service.projection.selectedSkill?.jobID == capturedJobID,
               service.exportSkillDraft(capturedDraft, to: url) {
                exportMessage = L("Skill draft exported.", "Skill 草稿已导出。")
            } else {
                exportMessage = L("Could not export the skill draft.", "无法导出 Skill 草稿。")
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07)))
            )
    }

    private func cardHeading(title: String, icon: String, status: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(OverlayTheme.accent)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let status {
                statusBadge(status)
            }
            Spacer()
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(statusLabel(status))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor(status).opacity(0.12)))
    }

    private func caveatBlock(_ caveats: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(caveats.enumerated()), id: \.offset) { _, caveat in
                Label(caveat, systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OverlayTheme.warning)
            }
        }
    }

    private func notice(title: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(OverlayTheme.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
    }

    private func jobStateText(_ state: AnalysisJobState, kind: AnalysisJobKind) -> String {
        switch state.status {
        case "pending", "running":
            return kind == .requirement
                ? L("Requirement analysis is in progress.", "需求分析进行中。")
                : L("Summary analysis is in progress.", "摘要分析进行中。")
        case "failed":
            return state.error.map { L("Analysis failed: \($0)", "分析失败：\($0)") }
                ?? L("Analysis failed.", "分析失败。")
        case "not_analyzed":
            return L("Not analyzed yet.", "尚未分析。")
        default:
            return L("No result recorded.", "未记录结果。")
        }
    }

    private func jobStateText(_ skill: AnalysisSkill) -> String {
        switch skill.status {
        case "pending", "running": return L("Skill extraction is in progress.", "Skill 提取进行中。")
        case "failed": return skill.error.map { L("Extraction failed: \($0)", "提取失败：\($0)") } ?? L("Extraction failed.", "提取失败。")
        default: return L("No skill draft recorded.", "未记录 Skill 草稿。")
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "succeeded": return L("Done", "完成")
        case "pending": return L("Pending", "等待")
        case "running": return L("Running", "运行中")
        case "failed": return L("Failed", "失败")
        case "not_analyzed": return L("Not analyzed", "未分析")
        default: return status
        }
    }

    private func shortStatus(_ turn: AnalysisTurn) -> String {
        if turn.summary.status == "succeeded" { return L("Done", "完成") }
        if turn.originalResult == nil { return L("Waiting", "等待回复") }
        return statusLabel(turn.summary.status)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "succeeded": return OverlayTheme.good
        case "failed": return .red
        case "pending", "running": return OverlayTheme.warning
        default: return OverlayTheme.muted
        }
    }
}
