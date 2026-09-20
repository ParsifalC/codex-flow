import SwiftUI

/// Shared completed-turn details. Missing metadata is never inferred from messages.
public struct TurnDetailView: View {
    public let run: TaskRun
    public let isPrivacyMode: Bool
    @State private var resultExpanded = false
    @State private var planExpanded = true
    @State private var jsonExpanded = false

    public init(run: TaskRun, isPrivacyMode: Bool = false) {
        self.run = run; self.isPrivacyMode = isPrivacyMode
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                narrative(
                    L("This turn’s goal", "本轮目标"),
                    hint: run.isLegacyGoalFallback ? L("Legacy history", "历史兼容") : L("Extracted need", "需求提炼"),
                    text: run.publishedGoal,
                    accent: true
                )
                Divider().overlay(Color.white.opacity(0.08))
                narrative(
                    L("Result", "结果"),
                    hint: run.isLegacyConclusionFallback ? L("Legacy history", "历史兼容") : nil,
                    text: run.publishedConclusion,
                    expanded: $resultExpanded,
                    accent: false
                )
                if run.result?.truncated == true {
                    Text(L("Recorded result was truncated", "源结果已截断")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08)))
            HStack(spacing: 0) {
                fact(run.formattedDuration, L("Duration", "耗时"))
                Divider().frame(height: 28)
                fact(run.formattedTotalTokens, "Tokens")
                Divider().frame(height: 28)
                fact("\(run.allWorkers.count + 1)", L("Participants", "实际参与"))
            }.padding(.vertical, 4)
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
                        Text(L("The plan describes staffing by task stage; participation counts reflect agents recorded this turn. Reusing a plan does not mean running every stage again.", "计划列出任务各阶段的人员配置；参与人数统计本轮已记录的 Agent。沿用计划不代表每轮重跑所有阶段。"))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
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
            .font(.system(size: 14)).tint(.white.opacity(0.7)).padding(13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
        }
        .onChange(of: run.id) { _, _ in
            resultExpanded = false; planExpanded = true; jsonExpanded = false
        }
    }
    private func narrative(_ title: String, hint: String?, text: String?, expanded: Binding<Bool>? = nil, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).fontWeight(.semibold); Spacer()
                if let hint { Text(hint).foregroundStyle(.white.opacity(0.72)) }
            }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Text(isPrivacyMode ? L("Hidden in privacy mode", "隐私模式已隐藏") : localizedResultText(text))
                .font(.system(size: accent ? 16 : 14, weight: accent ? .semibold : .regular))
                .foregroundStyle(text == nil ? .white.opacity(0.7) : .white.opacity(0.94))
                .lineSpacing(6).lineLimit(expanded?.wrappedValue == false ? 5 : nil)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let expanded, text != nil && !isPrivacyMode {
                Button(expanded.wrappedValue ? L("Show less", "收起全文") : L("Read full text", "展开全文")) { expanded.wrappedValue.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.cyan.opacity(0.9))
            }
        }
    }
    private func fact(_ value: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
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
