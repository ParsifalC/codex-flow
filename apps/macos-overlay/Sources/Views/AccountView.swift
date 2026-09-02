import SwiftUI
import Foundation

public struct AccountView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    public var isFullHeight: Bool = false

    @State private var snapshot: AccountSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?

    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state
        self.isFullHeight = isFullHeight
    }

    public var body: some View {
        let content = VStack(spacing: 9) {
            accountHeader
            StrategyModeCard()

            if isLoading && snapshot == nil {
                loadingState
            } else if let snapshot {
                identityCard(snapshot)
                quotaCard(snapshot)
                resetCard(snapshot)
                accountFactsCard(snapshot)
            } else {
                unavailableState
            }
        }
        .padding(.vertical, 2)

        return Group {
            if isFullHeight {
                content
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    content
                }
                .frame(maxHeight: 390)
            }
        }
        .onAppear(perform: refresh)
    }

    private var accountHeader: some View {
        HStack(spacing: 9) {
            FlowPilotLogoView(size: 42, showGlow: true, withBolt: false, text: "FP")
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("Account & Limits", "账户与额度"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(L("Account data from Codex · strategy from FlowPilot policy", "账户数据来自 Codex · 策略来自 FlowPilot 配置"))
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.cyan)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.cyan.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("Reading account status…", "正在读取账户状态…"))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var unavailableState: some View {
        VStack(spacing: 7) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 22))
                .foregroundColor(.orange.opacity(0.8))
            Text(errorMessage ?? L("Account data unavailable", "账户数据暂不可用"))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            Text(L("FlowPilot will not estimate plan or quota values when Codex does not report them.", "Codex 未返回的数据，FlowPilot 不会进行估算。"))
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(cardBackground)
    }

    private func identityCard(_ value: AccountSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("CURRENT PLAN", "当前 PLAN"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                Text(planDisplayName(value.planType))
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .indigo], startPoint: .leading, endPoint: .trailing))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(accountTypeDisplayName(value.accountType))
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))

                if let email = value.email, !email.isEmpty {
                    HoverRevealText(
                        email,
                        font: .system(size: 8.5),
                        foregroundColor: .white.opacity(0.48),
                        lineLimit: 1,
                        privacyBlur: state.isPrivacyMode,
                        popoverWidth: 300
                    )
                    .frame(maxWidth: 190, alignment: .trailing)
                }
            }
        }
        .padding(9)
        .background(cardBackground)
    }

    private func quotaCard(_ value: AccountSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L("Current quota", "当前额度"), systemImage: "gauge.with.needle.fill")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                Spacer()
                if value.quotaWindows.isEmpty {
                    Text(L("Not reported", "未返回"))
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if value.quotaWindows.isEmpty {
                Text(L("Codex did not return a rate-limit window for this account.", "Codex 当前没有返回该账户的额度窗口。"))
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(value.orderedWindows) { window in
                    quotaRow(window)
                }
            }
        }
        .padding(9)
        .background(cardBackground)
    }

    private func quotaRow(_ window: AccountQuotaWindow) -> some View {
        let used = window.usedPercent.map { max(0, min(100, $0)) }
        let remaining = window.remainingPercent
        let remainingFraction = max(0, min(1, (remaining ?? 0) / 100.0))
        let pressure = used ?? 0
        let accent: Color = pressure >= 85 ? .orange : (pressure >= 60 ? .yellow : .cyan)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(window.compactName)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(accent)
                    .frame(width: 48, alignment: .leading)
                Text(window.displayName)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                Spacer()
                if let remaining {
                    Text(String(format: L("%.0f%% left", "剩余 %.0f%%"), remaining))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(accent)
                } else {
                    Text(L("Not reported", "未返回"))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    if remaining != nil {
                        Capsule().fill(accent)
                            .frame(width: proxy.size.width * CGFloat(remainingFraction))
                    }
                }
            }
            .frame(height: 4)

            HStack {
                if let used {
                    Text(String(format: L("Used %.0f%%", "已用 %.0f%%"), used))
                        .font(.system(size: 7.8))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    Text(L("Usage not reported", "用量未返回"))
                        .font(.system(size: 7.8))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Text(window.resetsAt.map { L("Resets \(formatAccountDate($0))", "\(formatAccountDate($0)) 重置") } ?? L("Reset time unavailable", "重置时间未返回"))
                    .font(.system(size: 7.8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.52))
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.025)))
    }

    private func resetCard(_ value: AccountSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("RESET CREDITS AVAILABLE", "可用重置次数"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                Text(value.resetCreditCount.map(String.init) ?? "—")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor((value.resetCreditCount ?? 0) > 0 ? .cyan : .white.opacity(0.8))
            }

            Divider().frame(height: 30).overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("NEXT CREDIT EXPIRY", "重置次数到期"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                Text(value.nearestResetCreditExpiry.map(formatAccountDate) ?? L("No expiry reported", "未返回到期时间"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
            }
            Spacer()
        }
        .padding(9)
        .background(cardBackground)
    }

    private func accountFactsCard(_ value: AccountSnapshot) -> some View {
        VStack(spacing: 5) {
            factRow(L("Credits", "Credits"), creditsDisplay(value))
            factRow(L("Rate limit state", "限额状态"), rateLimitStateDisplay(value))
            factRow(L("Spend control", "消费控制"), booleanStatus(value.spendControlReached, trueText: L("Reached", "已触发"), falseText: L("Normal", "正常")))
            factRow(L("OpenAI auth", "OpenAI 认证"), booleanStatus(value.requiresOpenAIAuth, trueText: L("Required", "需要"), falseText: L("Not required", "不需要")))
            factRow(L("Last refreshed", "最后刷新"), formatAccountDate(value.fetchedAt))
        }
        .padding(9)
        .background(cardBackground)
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            HoverRevealText(
                value,
                font: .system(size: 8.5, weight: .semibold, design: .rounded),
                foregroundColor: .white.opacity(0.78),
                lineLimit: 1,
                popoverWidth: 300
            )
            .frame(maxWidth: 190, alignment: .trailing)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try AccountSnapshotService.load()
                DispatchQueue.main.async {
                    snapshot = value
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func planDisplayName(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based": return "Business"
        case "enterprise", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "ent26": return "Enterprise"
        case "edu": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        case "unknown": return L("Unknown", "未知")
        case .some(let value): return value.replacingOccurrences(of: "_", with: " ").capitalized
        case .none: return L("Not reported", "未返回")
        }
    }

    private func accountTypeDisplayName(_ raw: String?) -> String {
        switch raw {
        case "chatgpt": return "ChatGPT"
        case "apiKey": return "API Key"
        case "amazonBedrock": return "Bedrock"
        default: return raw ?? L("Account", "账户")
        }
    }

    private func creditsDisplay(_ value: AccountSnapshot) -> String {
        if value.unlimitedCredits == true { return L("Unlimited", "无限") }
        if let balance = value.creditsBalance { return balance }
        if value.hasCredits == false { return L("No credit balance", "无 Credits 余额") }
        return L("Not reported", "未返回")
    }

    private func rateLimitStateDisplay(_ value: AccountSnapshot) -> String {
        guard let state = value.rateLimitReachedType, !state.isEmpty else {
            return L("Not reported", "未返回")
        }
        switch state.lowercased() {
        case "rate_limit_reached":
            return L("Rate limit reached", "已达到额度上限")
        case "workspace_owner_credits_depleted":
            return L("Workspace credits depleted", "工作区 Credits 已用尽")
        case "workspace_member_credits_depleted":
            return L("Member credits depleted", "成员 Credits 已用尽")
        case "workspace_owner_usage_limit_reached":
            return L("Workspace usage limit reached", "工作区用量上限已达到")
        case "workspace_member_usage_limit_reached":
            return L("Member usage limit reached", "成员用量上限已达到")
        default:
            return state.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func booleanStatus(_ value: Bool?, trueText: String, falseText: String) -> String {
        guard let value else { return L("Not reported", "未返回") }
        return value ? trueText : falseText
    }
}
