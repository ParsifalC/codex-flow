import SwiftUI
import Foundation

public struct AccountView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    public var isFullHeight: Bool = false

    @State private var snapshot: AccountSnapshot? = AccountSnapshotService.cached
    @State private var preferencesExpanded = false
    @State private var accountDetailsExpanded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = AccountSnapshotService.cached != nil

    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state
        self.isFullHeight = isFullHeight
        let cached = AccountSnapshotService.cached
        _snapshot = State(initialValue: cached)
        _hasLoaded = State(initialValue: cached != nil)
    }

    public var body: some View {
        let content = VStack(spacing: 20) {
            accountHeader

            if snapshot == nil && (isLoading || !hasLoaded) {
                loadingState
            } else if snapshot == nil, let errorMessage {
                errorState(errorMessage)
            } else if let snapshot, !snapshot.isEmpty {
                if let errorMessage {
                    staleDataWarning(errorMessage)
                }
                identityCard(snapshot)
                OverlayDivider()
                quotaCard(snapshot)
                OverlayDivider()
                resetCard(snapshot)
                factRow("Credits", creditsDisplay(snapshot))
                DisclosureGroup(L("More account information", "更多账户信息"), isExpanded: $accountDetailsExpanded) {
                    accountFactsCard(snapshot).padding(.top, 14)
                }.font(.system(size: 12.5)).tint(OverlayTheme.secondary)
            } else {
                emptyState
            }

            DisclosureGroup(L("Preferences", "偏好设置"), isExpanded: $preferencesExpanded) {
                VStack(spacing: 14) {
                    StrategyModeCard()
                    AutostartCard()
                    PetSettingsCard(state: state)
                }.padding(.top, 14)
            }.font(.system(size: 12.5)).tint(OverlayTheme.secondary)
        }
        .padding(.vertical, 20)

        return Group {
            if isFullHeight {
                content
            } else {
                ScrollView(.vertical, showsIndicators: true) { content }
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            if snapshot == nil, let cached = AccountSnapshotService.cached {
                snapshot = cached
                hasLoaded = true
            }
            refresh()
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Account & Limits", "账户与额度"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text(L("Account and preferences", "账户信息与偏好设置"))
                    .font(.system(size: 11.5))
                    .foregroundColor(OverlayTheme.muted)
            }

            Spacer()

            Button(action: refresh) {
                if isLoading && snapshot != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(OverlayTheme.accent)
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(OverlayButtonStyle())
            .disabled(isLoading)
            .help(L("Refresh account information", "刷新账户信息"))
            .accessibilityLabel(L("Refresh account information", "刷新账户信息"))
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("Reading account status…", "正在读取账户状态…"))
                .font(.system(size: 13))
                .foregroundColor(OverlayTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 22))
                .foregroundColor(.orange.opacity(0.8))
            Text(L("Unable to read account data", "无法读取账户数据"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OverlayTheme.secondary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(OverlayTheme.muted)
                .multilineTextAlignment(.center)
            Button(L("Retry", "重试"), action: refresh)
                .buttonStyle(OverlayButtonStyle())
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(OverlayTheme.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120)

    }

    private func staleDataWarning(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(.orange)
            Text(L("Refresh failed: \(message) (showing cached data)", "刷新失败：\(message)（已展示缓存数据）"))
                .font(.system(size: 13))
                .foregroundColor(OverlayTheme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button(L("Retry", "重试"), action: refresh)
                .buttonStyle(OverlayButtonStyle())
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(OverlayTheme.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.orange.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.orange.opacity(0.25), lineWidth: 0.6))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 22))
                .foregroundColor(OverlayTheme.muted)
            Text(L("No account data reported", "Codex 未返回账户数据"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OverlayTheme.secondary)
            Text(L("Codex returned an empty account and quota response.", "Codex 返回了空的账户与额度响应。"))
                .font(.system(size: 13))
                .foregroundColor(OverlayTheme.muted)
                .multilineTextAlignment(.center)
            Button(L("Retry", "重试"), action: refresh)
                .buttonStyle(OverlayButtonStyle())
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(OverlayTheme.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120)

    }

    private func identityCard(_ value: AccountSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("CURRENT PLAN", "当前 PLAN"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(OverlayTheme.muted)
                Text(planDisplayName(value.planType))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(accountTypeDisplayName(value.accountType))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(OverlayTheme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.07)))

                if let email = value.email, !email.isEmpty {
                    HoverRevealText(
                        email,
                        font: .system(size: 11.5, design: .monospaced),
                        foregroundColor: .white.opacity(0.52),
                        lineLimit: 1,
                        privacyBlur: state.isPrivacyMode,
                        popoverWidth: 300
                    )
                    .frame(maxWidth: 190, alignment: .trailing)
                }
            }
        }


    }

    enum QuotaTabMode: String, CaseIterable {
        case window
        case daily
    }
    @State private var quotaTabMode: QuotaTabMode = .window

    private func quotaCard(_ value: AccountSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(
                    quotaTabMode == .window ? L("Current quota", "当前额度") : L("Daily quota usage", "每日额度消耗"),
                    systemImage: quotaTabMode == .window ? "gauge.with.needle.fill" : "chart.bar.fill"
                )
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))

                Spacer()

                HStack(spacing: 2) {
                    quotaTabButton(mode: .window, title: L("Window", "额度窗口"))
                    quotaTabButton(mode: .daily, title: L("Daily", "每日消耗"))
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            if quotaTabMode == .window {
                if value.orderedWindows.filter({ $0.durationMinutes != 300 }).isEmpty {
                    Text(L("Codex did not return a rate-limit window for this account.", "Codex 当前没有返回该账户的额度窗口。"))
                        .font(.system(size: 13))
                        .foregroundColor(OverlayTheme.muted)
                } else {
                    ForEach(value.orderedWindows.filter { $0.durationMinutes != 300 }) { window in
                        quotaRow(window)
                    }
                }
            } else {
                dailyQuotaView(value)
            }
        }

    }

    private func quotaTabButton(mode: QuotaTabMode, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                quotaTabMode = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(quotaTabMode == mode ? .white : .white.opacity(0.45))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(quotaTabMode == mode ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(OverlayButtonStyle())
    }

    private func dailyQuotaView(_ value: AccountSnapshot) -> some View {
        let currentAccountId = value.accountId
        let weeklySlot = value.weeklyWindow?.slot
        let dailyUsages = TelemetryQueryEngine.shared.computeDailyQuotaUsage(days: 7, accountId: currentAccountId, bucketId: weeklySlot)
        let knownDeltas: [Double] = dailyUsages.compactMap { $0.quotaDelta }
        let maxDelta = max(1.0, knownDeltas.max() ?? 1.0)
        let totalRecentDelta = knownDeltas.reduce(0, +)
        let todayUsage = dailyUsages.first

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("TODAY'S OBSERVED USAGE", "今日已观测周额度消耗"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(OverlayTheme.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let todayDelta = todayUsage?.quotaDelta {
                            Text(String(format: "%.1f pp", todayDelta))
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundColor(todayDelta > 0 ? .orange : .white.opacity(0.8))
                        } else {
                            let pending = todayUsage?.crossMidnightPendingPp ?? 0.0
                            Text("—")
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundColor(OverlayTheme.muted)
                                .help(pending > 0 ? String(format: L("Pending cross-midnight allocation: %.1f pp", "跨日待分配：%.1f pp"), pending) : "")
                        }
                        if let tokens = todayUsage?.tokens, tokens > 0 {
                            Text("· \(TaskRun.formatTokenCount(tokens))")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(OverlayTheme.muted)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("7-DAY TOTAL", "近 7 天消耗"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(OverlayTheme.muted)
                    if !knownDeltas.isEmpty {
                        Text(String(format: "%.0f%%", totalRecentDelta))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(OverlayTheme.accent)
                    } else {
                        Text("—")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(OverlayTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            VStack(spacing: 4) {
                ForEach(dailyUsages) { item in
                    dailyQuotaRow(item, maxDelta: maxDelta)
                }
            }
        }
    }

    private func dailyQuotaRow(_ item: DailyQuotaUsage, maxDelta: Double) -> some View {
        let deltaVal = item.quotaDelta ?? 0.0
        let fraction = max(0.0, min(1.0, deltaVal / maxDelta))
        let accent: Color = deltaVal >= 10 ? .orange : (deltaVal > 0 ? .cyan : .white.opacity(0.2))

        return HStack(spacing: 6) {
            Text(item.displayDate)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 36, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    if deltaVal > 0 {
                        Capsule().fill(accent)
                            .frame(width: max(4, proxy.size.width * CGFloat(fraction)))
                    }
                }
            }
            .frame(height: 4)

            HStack(spacing: 3) {
                if let delta = item.quotaDelta {
                    if delta > 0 {
                        Text(String(format: "%.0f%%", delta))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(accent)
                    } else {
                        Text("0%")
                            .font(.system(size: 13))
                            .foregroundColor(OverlayTheme.muted)
                    }
                } else {
                    let pending = item.crossMidnightPendingPp ?? 0.0
                    Text("—")
                        .font(.system(size: 13))
                        .foregroundColor(OverlayTheme.muted)
                        .help(pending > 0 ? String(format: L("Pending cross-midnight allocation: %.1f pp", "跨日待分配：%.1f pp"), pending) : "")
                }

                if item.runs > 0 {
                    Text("(\(item.runs)\(L(" runs", "次")))")
                        .font(.system(size: 13))
                        .foregroundColor(OverlayTheme.muted)
                }
            }
            .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.02))
        )
    }

    private func quotaRow(_ window: AccountQuotaWindow) -> some View {
        let used = window.usedPercent.flatMap { $0.isFinite ? max(0, min(100, $0)) : nil }
        let remaining = used.map { 100 - $0 }
        let low = (remaining ?? 100) <= 40
        let accent = low ? OverlayTheme.warning : OverlayTheme.accent
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(window.durationMinutes == 10_080 ? L("Weekly quota", "周额度") : window.displayName)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(OverlayTheme.secondary)
                if low {
                    Text(L("Low", "偏低")).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accent).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
                Spacer()
                Text(remaining.map { String(format: L("%.1f%% left", "剩余 %.1f%%"), $0) } ?? L("Not reported", "未返回"))
                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(accent)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    if let used {
                        Capsule().fill(accent).frame(width: proxy.size.width * used / 100)
                    }
                }
            }.frame(height: 8)
            HStack(alignment: .top) {
                Text(used.map { String(format: L("Used %.1f%%", "已用 %.1f%%"), $0) } ?? L("Usage not reported", "用量未返回"))
                Spacer()
                Text(window.resetsAt.map { L("Resets \(formatAccountDate($0))", "\(formatAccountDate($0)) 重置") } ?? L("Reset time unavailable", "重置时间未返回"))
                    .multilineTextAlignment(.trailing)
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(OverlayTheme.muted)
        }
    }

    private func resetCard(_ value: AccountSnapshot) -> some View {
        VStack(spacing: 14) {
            factRow(L("Reset credits available", "可用重置次数"), value.resetCreditCount.map(String.init) ?? "—")
            factRow(L("Next credit expiry", "重置次数到期"), value.nearestResetCreditExpiry.map(formatAccountDate) ?? L("No expiry reported", "未返回到期时间"))
        }

    }

    private func accountFactsCard(_ value: AccountSnapshot) -> some View {
        VStack(spacing: 14) {
            factRow(L("Rate limit state", "限额状态"), rateLimitStateDisplay(value))
            factRow(L("Spend control", "消费控制"), booleanStatus(value.spendControlReached, trueText: L("Reached", "已触发"), falseText: L("Normal", "正常")))
            factRow(L("OpenAI auth", "OpenAI 认证"), booleanStatus(value.requiresOpenAIAuth, trueText: L("Required", "需要"), falseText: L("Not required", "不需要")))
            factRow(L("Last refreshed", "最后刷新"), formatAccountDate(value.fetchedAt))
        }


    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(OverlayTheme.muted)
            Spacer()
            HoverRevealText(
                value,
                font: .system(size: 14, weight: .semibold, design: .monospaced),
                foregroundColor: .white.opacity(0.78),
                lineLimit: 1,
                popoverWidth: 300
            )
            .frame(maxWidth: 190, alignment: .trailing)
        }
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
                    hasLoaded = true
                    errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    hasLoaded = true
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
