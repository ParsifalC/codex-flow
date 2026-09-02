import Foundation
import Combine

public enum AppLanguage: String {
    case zh
    case en
}

public final class AppLocalization: ObservableObject {
    public static let shared = AppLocalization()

    @Published public private(set) var language: AppLanguage
    private var refreshTimer: Timer?

    private init() {
        language = Self.resolveLanguage()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let resolved = Self.resolveLanguage()
            if resolved != self.language {
                self.language = resolved
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    public func text(_ english: String, _ chinese: String) -> String {
        language == .zh ? chinese : english
    }

    public static func resolveLanguage() -> AppLanguage {
        let env = ProcessInfo.processInfo.environment
        if let rawOverride = env["CODEX_FLOW_LANGUAGE"], !rawOverride.isEmpty {
            return resolve(normalize(rawOverride) ?? "auto")
        }
        return resolve(configuredLanguage())
    }

    public static func configuredLanguage() -> String {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        let policy = URL(fileURLWithPath: codexHome).appendingPathComponent("codex-flow.toml")
        guard let text = try? String(contentsOf: policy, encoding: .utf8) else { return "auto" }

        var inUI = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inUI = line == "[ui]"
                continue
            }
            guard inUI else { continue }
            let noComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard noComment.hasPrefix("language"), let eq = noComment.firstIndex(of: "=") else { continue }
            let rawValue = noComment[noComment.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return normalize(rawValue) ?? "auto"
        }
        return "auto"
    }

    public static func systemLanguage() -> AppLanguage {
        for candidate in Locale.preferredLanguages {
            if let normalized = normalize(candidate), normalized != "auto" {
                return normalized == "zh" ? .zh : .en
            }
        }

        let env = ProcessInfo.processInfo.environment
        for key in ["LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"] {
            if let normalized = normalize(env[key]), normalized != "auto" {
                return normalized == "zh" ? .zh : .en
            }
        }
        return .en
    }

    private static func resolve(_ normalized: String) -> AppLanguage {
        switch normalized {
        case "zh": return .zh
        case "en": return .en
        default: return systemLanguage()
        }
    }

    private static func normalize(_ raw: String?) -> String? {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if value.isEmpty || ["auto", "system", "default"].contains(value) { return "auto" }
        if value == "zh" || value.hasPrefix("zh-") || value.hasPrefix("chinese") { return "zh" }
        if value == "en" || value.hasPrefix("en-") || value.hasPrefix("english") { return "en" }
        return nil
    }
}

@inline(__always)
public func L(_ english: String, _ chinese: String) -> String {
    AppLocalization.shared.text(english, chinese)
}

public func localizedRole(_ role: String) -> String {
    switch role.lowercased() {
    case "parent": return L("parent", "父 Agent")
    case "worker", "subagent": return L("worker", "Worker")
    default: return role
    }
}

public extension OverlayTab {
    var localizedTitle: String {
        switch self {
        case .inspector: return L("Inspector", "任务")
        case .history: return L("History", "历史")
        case .analytics: return L("Analytics", "统计")
        }
    }
}

public extension QuotaWindow {
    var localizedFormattedResetsAt: String? {
        guard let r = resetsAt, r > 0 else { return nil }
        let date = Date(timeIntervalSince1970: r > 1_000_000_000_000 ? r / 1000.0 : r)
        let interval = date.timeIntervalSince(Date())
        if interval > 0 && interval < 86400 {
            let mins = Int(interval) / 60
            if mins < 60 {
                return L("resets in \(mins)m", "\(mins) 分钟后重置")
            }
            let hours = mins / 60
            let remMins = mins % 60
            return L("resets in \(hours)h \(remMins)m", "\(hours) 小时 \(remMins) 分钟后重置")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return L("resets at \(formatter.string(from: date))", "\(formatter.string(from: date)) 重置")
    }
}

public extension TaskRun {
    var localizedFormattedDate: String {
        guard let s = startedAtMs else { return "--:--" }
        let date = Date(timeIntervalSince1970: s / 1000.0)
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return L("Today \(formatter.string(from: date))", "今天 \(formatter.string(from: date))")
        }
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

public extension ChatSession {
    var localizedRunsSummary: String {
        let count = runs.count
        return count == 1 ? L("1 session", "1 次会话") : L("\(count) sessions", "\(count) 轮会话")
    }
}

