import SwiftUI
import Foundation

// MARK: - Deterministic account snapshot from Codex app-server

public struct AccountQuotaWindow: Identifiable {
    public let id: String
    public let durationMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?

    public var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    public var displayName: String {
        guard let mins = durationMinutes else { return L("Usage window", "额度窗口") }
        switch mins {
        case 300:
            return L("5 hour limit", "5 小时额度")
        case 10080:
            return L("Weekly limit", "每周额度")
        default:
            if mins < 60 { return "\(mins)m" }
            if mins < 1440 { return "\(mins / 60)h" }
            return "\(mins / 1440)d"
        }
    }

    public var compactName: String {
        guard let mins = durationMinutes else { return "—" }
        if mins == 300 { return "5h" }
        if mins == 10080 { return L("Weekly", "Weekly") }
        if mins < 60 { return "\(mins)m" }
        if mins < 1440 { return "\(mins / 60)h" }
        return "\(mins / 1440)d"
    }
}

public struct AccountResetCredit: Identifiable {
    public let id: String
    public let status: String?
    public let expiresAt: Date?
    public let title: String?
}

public struct AccountSnapshot {
    public let accountType: String?
    public let email: String?
    public let planType: String?
    public let requiresOpenAIAuth: Bool?
    public let quotaWindows: [AccountQuotaWindow]
    public let resetCreditCount: Int?
    public let resetCredits: [AccountResetCredit]
    public let hasCredits: Bool?
    public let unlimitedCredits: Bool?
    public let creditsBalance: String?
    public let spendControlReached: Bool?
    public let rateLimitReachedType: String?
    public let fetchedAt: Date

    public var fiveHourWindow: AccountQuotaWindow? {
        quotaWindows.first { $0.durationMinutes == 300 }
    }

    public var weeklyWindow: AccountQuotaWindow? {
        quotaWindows.first { $0.durationMinutes == 10080 }
    }

    public var orderedWindows: [AccountQuotaWindow] {
        var result: [AccountQuotaWindow] = []
        if let fiveHourWindow { result.append(fiveHourWindow) }
        if let weeklyWindow { result.append(weeklyWindow) }
        let knownIds = Set(result.map(\.id))
        result.append(contentsOf: quotaWindows.filter { !knownIds.contains($0.id) }.sorted {
            ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max)
        })
        return result
    }

    public var nearestResetCreditExpiry: Date? {
        resetCredits.compactMap(\.expiresAt).filter { $0 > Date() }.min()
    }
}

private final class AppServerRPC {
    private struct Pending {
        let semaphore: DispatchSemaphore
        var result: [String: Any]?
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var buffer = Data()
    private var started = false

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data)
        }

        try process.run()
        started = true
    }

    deinit {
        close()
    }

    func initialize() -> Bool {
        let response = request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-flow",
                    "title": "FlowPilot Account",
                    "version": "1"
                ],
                "capabilities": ["experimentalApi": true]
            ],
            timeout: 4.0
        )
        guard response != nil else { return false }
        notify(method: "initialized", params: nil)
        return true
    }

    func request(method: String, params: [String: Any]?, timeout: TimeInterval = 4.0) -> [String: Any]? {
        lock.lock()
        let id = nextId
        nextId += 1
        let semaphore = DispatchSemaphore(value: 0)
        pending[id] = Pending(semaphore: semaphore, result: nil)
        lock.unlock()

        var payload: [String: Any] = ["id": id, "method": method]
        if let params { payload["params"] = params }
        guard send(payload) else {
            lock.lock()
            pending.removeValue(forKey: id)
            lock.unlock()
            return nil
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock()
            pending.removeValue(forKey: id)
            lock.unlock()
            return nil
        }

        lock.lock()
        let result = pending.removeValue(forKey: id)?.result
        lock.unlock()
        return result
    }

    func notify(method: String, params: [String: Any]?) {
        var payload: [String: Any] = ["method": method]
        if let params { payload["params"] = params }
        _ = send(payload)
    }

    func close() {
        guard started else { return }
        started = false
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func send(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let newline = Data([0x0A])
        var lines: [Data] = []
        while let range = buffer.range(of: newline) {
            lines.append(buffer.subdata(in: buffer.startIndex..<range.lowerBound))
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let idNumber = object["id"] as? NSNumber else { continue }
            let id = idNumber.intValue
            let result = object["result"] as? [String: Any]

            lock.lock()
            if var item = pending[id] {
                item.result = result
                pending[id] = item
                item.semaphore.signal()
            }
            lock.unlock()
        }
    }
}

public enum AccountSnapshotService {
    public static func load() throws -> AccountSnapshot {
        let rpc = try AppServerRPC()
        defer { rpc.close() }

        guard rpc.initialize() else {
            throw NSError(domain: "FlowPilot.Account", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("Codex app-server did not respond.", "Codex app-server 未响应。")
            ])
        }

        let accountResponse = rpc.request(method: "account/read", params: ["refreshToken": false])
        let limitsResponse = rpc.request(method: "account/rateLimits/read", params: nil)

        guard accountResponse != nil || limitsResponse != nil else {
            throw NSError(domain: "FlowPilot.Account", code: 2, userInfo: [
                NSLocalizedDescriptionKey: L("Account data is unavailable from Codex.", "Codex 暂未返回账户数据。")
            ])
        }

        let account = accountResponse?["account"] as? [String: Any]
        let requiresAuth = (accountResponse?["requiresOpenaiAuth"] as? NSNumber)?.boolValue

        let fallbackSnapshot = limitsResponse?["rateLimits"] as? [String: Any]
        let byId = limitsResponse?["rateLimitsByLimitId"] as? [String: Any]
        let codexSnapshot = (byId?["codex"] as? [String: Any]) ?? fallbackSnapshot ?? [:]

        var windows: [AccountQuotaWindow] = []
        for slot in ["primary", "secondary"] {
            guard let raw = codexSnapshot[slot] as? [String: Any] else { continue }
            let duration = intValue(raw["windowDurationMins"] ?? raw["windowMinutes"])
            let used = doubleValue(raw["usedPercent"])
            let reset = dateValue(raw["resetsAt"])
            windows.append(AccountQuotaWindow(
                id: "\(slot)-\(duration ?? 0)",
                durationMinutes: duration,
                usedPercent: used,
                resetsAt: reset
            ))
        }

        let resetSummary = limitsResponse?["rateLimitResetCredits"] as? [String: Any]
        let resetCount = intValue(resetSummary?["availableCount"])
        let rawCredits = resetSummary?["credits"] as? [[String: Any]] ?? []
        let resetCredits = rawCredits.compactMap { raw -> AccountResetCredit? in
            guard let id = raw["id"] as? String else { return nil }
            return AccountResetCredit(
                id: id,
                status: raw["status"] as? String,
                expiresAt: dateValue(raw["expiresAt"]),
                title: raw["title"] as? String
            )
        }

        let credits = codexSnapshot["credits"] as? [String: Any]
        let plan = (account?["planType"] as? String) ?? (codexSnapshot["planType"] as? String)

        return AccountSnapshot(
            accountType: account?["type"] as? String,
            email: account?["email"] as? String,
            planType: plan,
            requiresOpenAIAuth: requiresAuth,
            quotaWindows: windows,
            resetCreditCount: resetCount,
            resetCredits: resetCredits,
            hasCredits: (credits?["hasCredits"] as? NSNumber)?.boolValue,
            unlimitedCredits: (credits?["unlimited"] as? NSNumber)?.boolValue,
            creditsBalance: credits?["balance"] as? String,
            spendControlReached: (codexSnapshot["spendControlReached"] as? NSNumber)?.boolValue,
            rateLimitReachedType: codexSnapshot["rateLimitReachedType"] as? String,
            fetchedAt: Date()
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let raw = doubleValue(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000.0 : raw)
    }
}

// MARK: - Account UI

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
                Text(L("Live data from Codex app-server", "数据直接来自 Codex app-server"))
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
            ProgressView()
                .controlSize(.small)
            Text(L("Reading account status…", "正在读取账户状态…"))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
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
        .frame(maxWidth: .infinity, minHeight: 180)
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
                        font: .system(size: 8.5, weight: .regular),
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
        let used = max(0, min(100, window.usedPercent ?? 0))
        let remaining = window.remainingPercent
        let accent: Color = used >= 85 ? .orange : (used >= 60 ? .yellow : .cyan)

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
                    Text("—")
                        .foregroundColor(.white.opacity(0.35))
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(accent)
                        .frame(width: proxy.size.width * CGFloat(used / 100.0))
                }
            }
            .frame(height: 4)

            HStack {
                Text(String(format: L("Used %.0f%%", "已用 %.0f%%"), used))
                    .font(.system(size: 7.8))
                    .foregroundColor(.white.opacity(0.4))
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
                Text(L("USAGE RESETS", "额度重置次数"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                Text(value.resetCreditCount.map(String.init) ?? "—")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(value.resetCreditCount ?? 0 > 0 ? .cyan : .white.opacity(0.8))
            }

            Divider().frame(height: 30).overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("RESET CREDIT EXPIRY", "重置额度到期"))
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
            factRow(L("Rate limit state", "限额状态"), value.rateLimitReachedType ?? L("Available", "可用"))
            factRow(L("Spend control", "消费控制"), value.spendControlReached == true ? L("Reached", "已触发") : L("Normal / not reported", "正常 / 未返回"))
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
            Text(value)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(1)
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
}

public func formatAccountDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeZone = TimeZone.current
    let currentYear = Calendar.current.component(.year, from: Date())
    let targetYear = Calendar.current.component(.year, from: date)
    formatter.dateFormat = currentYear == targetYear ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}
