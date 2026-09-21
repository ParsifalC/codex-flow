import SwiftUI

/// Shared completed-turn details. Missing metadata is never inferred from messages.
public struct TurnDetailView: View {
    public let run: TaskRun
    public let isPrivacyMode: Bool
    @State private var resultExpanded = false
    @State private var planExpanded = false
    @State private var jsonExpanded = false

    public init(run: TaskRun, isPrivacyMode: Bool = false) {
        self.run = run; self.isPrivacyMode = isPrivacyMode
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                narrative(L("This turn’s goal", "本轮目标"), hint: run.publishedGoal == nil ? nil : L("Extracted need", "需求提炼"), text: run.publishedGoal, accent: true)
                OverlayDivider()
                narrative(L("Result", "结果"), hint: nil, text: run.publishedConclusion, expanded: $resultExpanded, accent: false)
                if run.result?.truncated == true {
                    Text(L("Recorded result was truncated", "源结果已截断")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.52))
                }
            }
            .padding(.vertical, 2)
            OverlayDivider()
            taskMetrics
            DisclosureGroup(isExpanded: $planExpanded) {
                VStack(alignment: .leading, spacing: 12) {
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
                    Spacer()
                    Text(run.turnContext?.orchestration == nil ? L("Not recorded", "未记录") : L("Orchestration", "编排计划"))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                }
            }
            .disclosureGroupStyle(OverlayDisclosureStyle())
            .font(.system(size: 14)).tint(OverlayTheme.secondary)
            .overlay(alignment: .top) { OverlayDivider() }
        }
        .onChange(of: run.id) { _, _ in
            resultExpanded = false; planExpanded = false; jsonExpanded = false
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
                .font(.system(size: accent ? 19 : 13.5, weight: accent ? .semibold : .regular))
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
                    }
                }.frame(height: 6).accessibilityHidden(true)
                HStack(spacing: 16) {
                    tokenShare("Parent", count: tokens.parentTokens, share: tokens.parentShare, color: OverlayTheme.accent)
                    tokenShare("Worker", count: tokens.workerTokens, share: tokens.workerShare, color: OverlayTheme.good)
                }
            }
        }.padding(.vertical, 4)
    }
    private func tokenShare(_ title: String, count: Int?, share: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).foregroundStyle(OverlayTheme.secondary)
                Spacer(minLength: 0)
                Text(share.map { String(format: "%.1f%%", $0 * 100) } ?? "—").foregroundStyle(color)
            }.font(.system(size: 11.5, weight: .medium, design: .monospaced))
            Text(count.map { TaskRun.formatTokenCount($0) + " tokens" } ?? "—")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(OverlayTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(count.map { "\($0) tokens" } ?? L("Usage not recorded", "用量未记录"))
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
