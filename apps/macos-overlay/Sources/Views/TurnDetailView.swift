import SwiftUI

/// Shared completed-turn details. Missing metadata is never inferred from messages.
public struct TurnDetailView: View {
    public let run: TaskRun
    public let isPrivacyMode: Bool
    public var compact: Bool = false
    @State private var goalExpanded = false
    @State private var resultExpanded = false
    @State private var planExpanded = false
    @State private var jsonExpanded = false

    public init(run: TaskRun, isPrivacyMode: Bool = false, compact: Bool = false) {
        self.run = run; self.isPrivacyMode = isPrivacyMode; self.compact = compact
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                narrative(L("This turn’s goal", "本轮目标"), hint: L("Extracted need", "需求提炼"), text: run.publishedGoal, expanded: $goalExpanded, accent: true)
                Divider().overlay(Color.white.opacity(0.08))
                narrative(L("Result", "结果"), hint: nil, text: run.publishedConclusion, expanded: $resultExpanded, accent: false)
                if run.result?.truncated == true {
                    Text(L("Recorded result was truncated", "源结果已截断")).font(.system(size: 11)).foregroundStyle(.secondary)
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
                        planRow(L("Planned workers", "计划配置"), L("Explore", "探索") + " " + value(plan, "exploration_workers") + " · " + L("Implement", "实现") + " " + value(plan, "implementation_workers") + " · " + L("Review", "审查") + " " + value(plan, "reviewer_workers"))
                        planRow(L("Actual participants", "实际参与"), L("Parent 1 · Workers", "父 Agent 1 · 子 Agent") + " \(run.allWorkers.count)")
                        planRow(L("Plan origin", "计划来源"), origin(orchestration.origin))
                        planRow(L("Revision", "计划修订"), orchestration.revision.map(String.init) ?? L("Not recorded", "未记录"))
                        Text(L("Planned counts and actual participants are recorded separately.", "计划配置与实际参与人数分别记录。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        DisclosureGroup(L("Full plan JSON", "查看完整计划 JSON"), isExpanded: $jsonExpanded) {
                            ScrollView([.horizontal, .vertical]) {
                                Text(isPrivacyMode ? L("Hidden", "已隐藏") : prettyJSON(plan))
                                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(.vertical, 8)
                            }.frame(maxHeight: 220)
                        }
                    } else { Text(L("Not recorded", "未记录")).foregroundStyle(.secondary) }
                }.padding(.top, 14)
            } label: {
                HStack {
                    Text(L("Execution details", "执行详情")).fontWeight(.semibold)
                    Spacer()
                    Text(run.turnContext?.orchestration == nil ? L("Not recorded", "未记录") : L("Orchestration", "编排计划"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12)).tint(.white.opacity(0.7)).padding(13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
        }
        .onChange(of: run.id) { _, _ in
            goalExpanded = false; resultExpanded = false; planExpanded = false; jsonExpanded = false
        }
    }
    private func narrative(_ title: String, hint: String?, text: String?, expanded: Binding<Bool>, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).fontWeight(.semibold); Spacer()
                if let hint { Text(hint).foregroundStyle(.secondary) }
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            Text(isPrivacyMode ? L("Hidden in privacy mode", "隐私模式已隐藏") : localizedResultText(text))
                .font(.system(size: accent ? 15 : 13, weight: accent ? .medium : .regular))
                .foregroundStyle(text == nil ? .white.opacity(0.4) : .white.opacity(0.94))
                .lineSpacing(5).lineLimit(expanded.wrappedValue ? nil : (accent ? 3 : 5))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text != nil && !isPrivacyMode {
                Button(expanded.wrappedValue ? L("Show less", "收起全文") : L("Read full text", "展开全文")) { expanded.wrappedValue.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.cyan.opacity(0.9))
            }
        }
    }
    private func fact(_ value: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private func planRow(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(isPrivacyMode ? "•••" : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
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
