import SwiftUI
import AppKit

/// Shared completed-turn details with explicit provenance for request fallbacks.
public struct TurnDetailView: View {
    public let run: TaskRun
    public let isPrivacyMode: Bool
    public var analysis: ConversationAnalysisProjection?
    public var analysisService: ConversationAnalysisService?
    @State private var needExpanded = false
    @State private var summaryExpanded = false
    @State private var resultExpanded = false
    @State private var planExpanded = false
    @State private var jsonExpanded = false
    @State private var sourceExpanded = false
    @State private var skillExpanded = false
    @State private var skillDraft = AnalysisSkillDraftState()
    @State private var exportMessage: String?

    public init(run: TaskRun, isPrivacyMode: Bool = false,
                analysis: ConversationAnalysisProjection? = nil, analysisService: ConversationAnalysisService? = nil) {
        self.run = run; self.isPrivacyMode = isPrivacyMode
        self.analysis = analysis; self.analysisService = analysisService
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                if let analysis {
                    let need = analysis.selectedTurn?.requirement
                    let ready = need?.status == "succeeded" && need?.turnGoal != nil
                    narrative(L("Conversation goal", "会话目标"), hint: nil,
                        text: ready ? analysis.requirementText : need?.error == "context_limit_exceeded" ? L("Request history exceeds the analysis limit", "需求记录超出分析上限") : stateText(need?.status == "succeeded" ? nil : need?.status), accent: false)
                        .help(L("Conversation goal as of the selected turn", "截至所选轮次的会话目标"))
                    OverlayDivider()
                    narrative(L("Turn goal", "本轮目标"), hint: nil,
                        text: ready ? need?.turnGoal : L("Awaiting extraction", "待提炼"), accent: true)
                    coverageNote(need?.coverage)
                    DisclosureGroup(L("Need details", "需求详情"), isExpanded: $needExpanded) {
                        needDetails(need)
                    }.font(.system(size: 12)).disclosureGroupStyle(OverlayDisclosureStyle())
                    OverlayDivider()
                    narrative(L("Turn result", "本轮结果"), hint: nil,
                        text: analysis.summaryText ?? (analysis.selectedTurn?.summary.error == "context_limit_exceeded" ? L("Reply too long to summarize; open the original below", "回复超出摘要上限，请查看原文") : analysis.currentTurnWaitingForFinal ? L("Awaiting reply", "待回复") : stateText(analysis.selectedTurn?.summary.status)),
                        expanded: (analysis.summaryText?.count ?? 0) > 120 ? $summaryExpanded : nil, accent: false)
                    coverageNote(analysis.selectedTurn?.summary.coverage)
                    if !isPrivacyMode, !(analysis.selectedTurn?.summary.caveats.isEmpty ?? true) {
                        DisclosureGroup(L("Result qualifications", "结果说明")) { analysisNotes(analysis.selectedTurn?.summary) }
                            .font(.system(size: 12)).disclosureGroupStyle(OverlayDisclosureStyle())
                    }
                    if let original = analysis.originalResult ?? run.publishedConclusion {
                        DisclosureGroup(L("Full original reply", "回复原文"), isExpanded: $resultExpanded) {
                            Text(isPrivacyMode ? L("Hidden", "已隐藏") : original)
                                .font(.system(size: 13)).textSelection(.enabled)
                        }.disclosureGroupStyle(OverlayDisclosureStyle()).font(.system(size: 12))
                    }
                    if analysis.selectedTurn?.summary.status == "not_analyzed" && !analysis.currentTurnWaitingForFinal ||
                       need?.status == "not_analyzed" || (need?.status == "succeeded" && need?.turnGoal == nil) {
                        Button(L("Update extraction", "更新提炼")) { perform("analyze-turn") }
                            .disabled(isPrivacyMode || !analysis.snapshot.enabled)
                    }
                    if analysis.retryJobID(for: .requirement) != nil {
                        Button(L("Retry requirement", "重试需求")) { perform("retry", kind: .requirement) }.disabled(isPrivacyMode)
                    }
                    if analysis.retryJobID(for: .summary) != nil {
                        Button(L("Retry summary", "重试结果")) { perform("retry", kind: .summary) }.disabled(isPrivacyMode)
                    }
                } else {
                    narrative(L("Turn goal", "本轮目标"), hint: goalHint, text: run.publishedGoal, accent: true)
                    OverlayDivider()
                    narrative(L("Turn result", "本轮结果"), hint: nil, text: run.publishedConclusion,
                        expanded: $resultExpanded, accent: false)
                }
                if run.result?.truncated == true {
                    Text(L("Recorded result was truncated", "源结果已截断")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.52))
                }
            }
            .padding(.vertical, 2)
            if analysis != nil { OverlayDivider(); skillSection }
            OverlayDivider()
            DisclosureGroup(isExpanded: $planExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    taskMetrics
                    if let orchestration = run.turnContext?.orchestration, let plan = orchestration.executionPlan {
                        planRow(L("Strategy", "策略"), value(plan, "strategy"))
                        planRow(L("Routing", "路由"), value(plan, "routing"))
                        planRow(L("Review", "审查方式"), value(plan, "review_mode"))
                        planRow(L("Task worker plan", "任务计划配置"), L("Explore", "探索") + " " + value(plan, "exploration_workers") + " · " + L("Implement", "实现") + " " + value(plan, "implementation_workers") + " · " + L("Review", "审查") + " " + value(plan, "reviewer_workers"))
                        planRow(L("Observed this turn", "本轮记录参与"), L("Parent 1 · Workers", "父 Agent 1 · 子 Agent") + " \(run.allWorkers.count)")
                        planRow(L("Plan origin", "计划来源"), origin(orchestration.origin))
                        planRow(L("Revision", "计划修订"), orchestration.revision.map(String.init) ?? L("Not recorded", "未记录"))
                        DisclosureGroup(L("Full plan JSON", "查看完整计划 JSON"), isExpanded: $jsonExpanded) {
                            ScrollView([.horizontal, .vertical]) {
                                Text(isPrivacyMode ? L("Hidden", "已隐藏") : prettyJSON(plan))
                                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(.vertical, 8)
                            }.frame(maxHeight: 220)
                        }
                    } else { Text(L("Not recorded", "未记录")).foregroundStyle(.white.opacity(0.72)) }
                }.padding(.top, 14)
            } label: {
                HStack {
                    Text(L("Execution details", "执行详情")).fontWeight(.semibold)
                }
            }
            .disclosureGroupStyle(OverlayDisclosureStyle())
            .font(.system(size: 14)).tint(OverlayTheme.secondary)
            .overlay(alignment: .top) { OverlayDivider() }
        }
        // Recreate selectable native text views so accessibility drops cached private text.
        .id(isPrivacyMode)
        .onChange(of: run.id) { _, _ in
            resultExpanded = false; planExpanded = false; jsonExpanded = false
            needExpanded = false; summaryExpanded = false; sourceExpanded = false; skillExpanded = false; skillDraft = AnalysisSkillDraftState(); loadDraft()
        }
        .onAppear { loadDraft() }
        .onChange(of: analysis?.selectedSkill) { _, _ in loadDraft() }
        .onChange(of: isPrivacyMode) { _, hidden in if !hidden { loadDraft() } }
        .alert(L("Export skill", "导出 Skill"), isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button(L("OK", "好")) { exportMessage = nil }
        } message: { Text(exportMessage ?? "") }
    }

    @ViewBuilder private func needDetails(_ need: AnalysisJobState?) -> some View {
        if isPrivacyMode { Text(L("Hidden", "已隐藏")) }
        else {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Real need", "真正需求")).fontWeight(.semibold)
                Text(need?.text ?? L("Not analyzed yet", "尚未提炼"))
                needNotes(L("Evidence", "证据"), need?.evidence ?? [])
                needNotes(L("Conflict", "矛盾"), need?.conflicts ?? [])
                needNotes(L("Gap", "缺口"), need?.gaps ?? [])
                Text(L("Better wording", "更好说法")).fontWeight(.semibold)
                Text(need?.betterPrompt ?? L("Awaiting update", "待更新"))
                Text(L("Next step", "下一步")).fontWeight(.semibold)
                Text(need?.nextStep ?? L("Awaiting update", "待更新"))
                analysisNotes(need)
                DisclosureGroup(L("Original request", "原始发言"), isExpanded: $sourceExpanded) {
                    if let goal = run.publishedGoal { Text(goal) }
                    Text(analysis?.selectedTurn?.userText ?? "")
                }.disclosureGroupStyle(OverlayDisclosureStyle())
            }.textSelection(.enabled).padding(.top, 8)
        }
    }
    @ViewBuilder private func needNotes(_ title: String, _ values: [String]) -> some View {
        ForEach(values, id: \.self) { Text(title + ": " + $0).foregroundStyle(OverlayTheme.secondary) }
    }

    private func loadDraft() {
        if !isPrivacyMode { skillDraft.load(skill: analysis?.selectedSkill) }
    }
    private func perform(_ command: String, kind: AnalysisJobKind? = nil) {
        guard !isPrivacyMode else { return }
        _ = analysisService?.performForTurn(command, sessionID: run.sessionId, turnID: run.turnId, kind: kind)
    }
    private func stateText(_ status: String?) -> String {
        switch status {
        case "pending": return L("Queued for analysis…", "等待提炼…")
        case "running": return L("Analyzing…", "正在提炼…")
        case "failed": return L("Extraction failed", "提炼失败")
        default: return L("Not analyzed yet", "尚未提炼")
        }
    }
    @ViewBuilder private func coverageNote(_ coverage: AnalysisModelCoverage?) -> some View {
        if !isPrivacyMode, coverage?.inputTruncated == true {
            Text(L("Input is incomplete due to the length limit", "输入超出长度限制，未完整纳入分析"))
                .font(.system(size: 11)).foregroundStyle(OverlayTheme.warning)
        }
    }
    @ViewBuilder private func analysisNotes(_ job: AnalysisJobState?) -> some View {
        if !isPrivacyMode {
            if let revision = job?.revision {
                Text(L("Revision \(revision)", "修订 \(revision)")).font(.system(size: 10)).foregroundStyle(OverlayTheme.muted)
            }
            ForEach(job?.caveats ?? [], id: \.self) { text in
                Text(text).font(.system(size: 11)).foregroundStyle(OverlayTheme.warning)
            }
        }
    }
    private var skillSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(L("Extract skill", "提炼技能")) { skillExpanded = true; perform("extract-skill") }
                    .help(L("Extract from the conversation through this turn", "从会话开始至本轮提炼技能"))
                    .disabled(isPrivacyMode || analysis?.canExtractSkill != true || ["pending", "running"].contains(analysis?.selectedSkill?.status ?? ""))
            }
            if let skill = analysis?.selectedSkill {
                coverageNote(skill.coverage)
                DisclosureGroup(L("Skill draft", "技能草稿"), isExpanded: $skillExpanded) {
                    if isPrivacyMode { Text(L("Hidden in privacy mode", "隐私模式已隐藏")) }
                    else if skill.status == "succeeded" {
                        Text(skill.description ?? "").font(.system(size: 12)).foregroundStyle(OverlayTheme.secondary)
                        TextEditor(text: $skillDraft.text)
                            .font(.system(size: 12, design: .monospaced)).frame(height: 180)
                            .accessibilityLabel(L("Edit skill draft", "编辑技能草稿"))
                        ForEach(skill.caveats, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(OverlayTheme.warning) }
                        Button(L("Export SKILL.md", "导出 SKILL.md")) { exportSkill() }
                            .disabled(skillDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Text(stateText(skill.status)).font(.system(size: 12))
                        if skill.status == "failed" { Button(L("Retry", "重试")) { perform("retry", kind: .skill) } }
                    }
                }.disclosureGroupStyle(OverlayDisclosureStyle()).font(.system(size: 12))
            }
        }.buttonStyle(.plain).tint(OverlayTheme.accent)
    }
    private func exportSkill() {
        guard !isPrivacyMode, analysis?.canExportSkill == true else { return }
        let draft = skillDraft.text
        let job = analysis?.selectedSkill?.jobID
        let session = run.sessionId, turn = run.turnId
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SKILL.md"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let saved = analysisService?.exportDraft(draft, sessionID: session, turnID: turn, jobID: job, to: url) == true
            exportMessage = saved ? L("Skill draft exported.", "技能草稿已导出。") : L("Could not export the draft.", "无法导出草稿，请重试。")
        }
    }
    private var goalHint: String? {
        switch run.publishedGoalSource {
        case .turnContext: return L("Extracted need", "需求提炼")
        case .legacySummary: return L("Legacy history", "历史兼容")
        case .turnRequest: return L("Original request excerpt", "原始请求摘要")
        default: return nil
        }
    }
    private func narrative(_ title: String, hint: String?, text: String?, expanded: Binding<Bool>? = nil, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).fontWeight(.medium)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(OverlayTheme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(OverlayTheme.accent.opacity(0.12)))
                }
                Spacer(minLength: 0)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.52))
            Text(isPrivacyMode ? L("Hidden in privacy mode", "隐私模式已隐藏") : localizedResultText(text))
                .font(.system(size: accent ? 16 : 14, weight: accent ? .medium : .regular))
                .foregroundStyle(text == nil ? .white.opacity(0.52) : (accent ? .white.opacity(0.95) : .white.opacity(0.72)))
                .lineSpacing(accent ? 3 : 4).lineLimit(expanded?.wrappedValue == false ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let expanded, text != nil && !isPrivacyMode {
                Button(expanded.wrappedValue ? L("Show less", "收起全文") : L("Read full text", "展开全文")) { expanded.wrappedValue.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(OverlayTheme.accent)
            }
        }
    }
    private var taskMetrics: some View {
        let tokens = TurnTokenBreakdown(run: run)
        let quota = TurnWeeklyQuotaSummary(run: run)
        return VStack(spacing: 18) {
            HStack(spacing: 0) {
                fact(run.startedAtMs == nil || run.finishedAtMs == nil ? "—" : run.formattedDuration,
                     L("Total time", "总时间"))
                    .help(L("Elapsed time from this turn’s start to completion", "本轮开始至结束的总耗时"))
                OverlayDivider(vertical: true).frame(height: 32)
                fact(tokens.totalTokens.map(TaskRun.formatTokenCount) ?? "—", L("Total tokens", "总 Token"))
                    .help(tokens.totalTokens.map { "\($0) tokens" } ?? L("Token usage is incomplete", "Token 用量尚未完整记录"))
                OverlayDivider(vertical: true).frame(height: 32)
                fact(quotaChange(quota), L("Total quota change", "总变更额度"))
                    .help(quotaHelp(quota))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Token share", "Token 占比"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(OverlayTheme.muted)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.06))
                        if let parent = tokens.parentShare, let worker = tokens.workerShare {
                            HStack(spacing: 0) {
                                Rectangle().fill(OverlayTheme.accent).frame(width: geometry.size.width * parent)
                                Rectangle().fill(OverlayTheme.good).frame(width: geometry.size.width * worker)
                            }.clipShape(Capsule())
                        }
                        HStack {
                            barTokenCount(tokens.parentTokens, role: "Parent")
                            Spacer(minLength: 8)
                            barTokenCount(tokens.workerTokens, role: "Worker")
                        }.padding(.horizontal, 4)
                    }
                }.frame(height: 22)
                HStack(alignment: .top, spacing: 16) {
                    tokenShare("Parent", models: run.parent.map { [$0] } ?? [], share: tokens.parentShare, color: OverlayTheme.accent)
                    tokenShare("Worker", models: run.allWorkers, share: tokens.workerShare, color: OverlayTheme.good)
                }
            }
        }.padding(.vertical, 4)
    }
    private func barTokenCount(_ count: Int?, role: String) -> some View {
        Text(count.map { TaskRun.formatTokenCount($0) } ?? "—")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.black.opacity(0.65), in: Capsule())
            .accessibilityLabel(role + " " + (count.map { "\($0) tokens" } ?? L("Not recorded", "未记录")))
            .help(role + " " + (count.map { "\($0) tokens" } ?? L("Not recorded", "未记录")))
    }
    private func tokenShare(_ title: String, models: [ParticipantInfo], share: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).foregroundStyle(OverlayTheme.secondary)
                Spacer(minLength: 0)
                Text(share.map { String(format: "%.1f%%", $0 * 100) } ?? "—").foregroundStyle(color)
            }.font(.system(size: 11.5, weight: .medium, design: .monospaced))
            Text(modelNames(models))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(OverlayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(modelNames(models))
    }
    private func modelNames(_ participants: [ParticipantInfo]) -> String {
        guard !participants.isEmpty else { return "—" }
        return Array(Set(participants.map { participant in
            let model = participant.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return model.isEmpty || model == "unknown" ? L("Not recorded", "未记录") : model
        })).sorted().joined(separator: "\n")
    }
    private func quotaChange(_ quota: TurnWeeklyQuotaSummary) -> String {
        guard let consumption = quota.displayConsumption else { return quota.didReset ? L("Reset", "已重置") : "—" }
        let value = consumption == 0 ? 0 : -consumption
        let format = abs(value) > 0 && abs(value) < 0.01 ? "%+.4f pp" : "%+.2f pp"
        return (quota.usesObservedFallback ? "≈" : "") + String(format: format, value)
    }
    private func quotaHelp(_ quota: TurnWeeklyQuotaSummary) -> String {
        if quota.allocatedConsumption != nil {
            return L("Weekly quota change attributed to this turn, in percentage points.", "归因到当前轮次的周额度变化，单位为百分点。")
        }
        if quota.usesObservedFallback {
            return L("Account change used as a fallback; may include concurrent tasks.", "当前缺少任务归因值，使用账户额度变化兜底，可能包含并行任务。")
        }
        return L("Quota change not recorded", "额度变化未记录")
    }
    private func fact(_ value: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(OverlayTheme.primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.52))
        }.frame(maxWidth: .infinity)
    }
    private func planRow(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(.white.opacity(0.72)).frame(width: 90, alignment: .leading)
            Text(isPrivacyMode ? "•••" : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 13))
    }
    private func value(_ plan: JSONValue, _ key: String) -> String {
        guard case let .object(fields) = plan, let field = fields[key] else { return L("Not recorded", "未记录") }
        switch field {
        case .string(let text): return text
        case .number(let number): return String(format: "%.0f", number)
        default: return L("Not recorded", "未记录")
        }
    }
    private func origin(_ value: String?) -> String {
        switch value {
        case "compiled": return L("Compiled this turn", "本轮编译")
        case "reused": return L("Reused plan", "沿用计划")
        case "replanned": return L("Replanned", "重新编排")
        default: return L("Not recorded", "未记录")
        }
    }
    private func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
