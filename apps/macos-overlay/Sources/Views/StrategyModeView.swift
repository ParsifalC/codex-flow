import SwiftUI
import Foundation

public struct StrategyProfileInfo: Identifiable, Equatable {
    public let name: String
    public let description: String

    public var id: String { name }

    public var localizedName: String {
        switch name {
        case "efficient": return L("Efficient", "高效")
        case "balanced": return L("Balanced", "均衡")
        case "quality": return L("Quality", "质量")
        case "speed": return L("Speed", "速度")
        default: return name.capitalized
        }
    }

    public var localizedDescription: String {
        switch name {
        case "efficient": return L("Minimize quota waste and expensive parent usage.", "优先降低额度浪费和高成本父 Agent 使用。")
        case "balanced": return L("Balance quality, quota, and latency.", "在质量、额度与延迟之间取得平衡。")
        case "quality": return L("Maximize correctness and independent verification.", "优先正确性、深度推理与独立验证。")
        case "speed": return L("Minimize wall-clock time with safe parallelism.", "在安全并行边界内优先降低整体耗时。")
        default: return description
        }
    }

    public var iconName: String {
        switch name {
        case "efficient": return "leaf.fill"
        case "balanced": return "scale.3d"
        case "quality": return "checkmark.seal.fill"
        case "speed": return "bolt.fill"
        default: return "slider.horizontal.3"
        }
    }

    public var accent: Color {
        switch name {
        case "efficient": return .green
        case "balanced": return .cyan
        case "quality": return .purple
        case "speed": return .orange
        default: return .cyan
        }
    }
}

public struct StrategyModeSnapshot {
    public let configured: String
    public let routing: String?
    public let valid: Bool
    public let profiles: [StrategyProfileInfo]
}

public enum StrategyModeService {
    public static func load() throws -> StrategyModeSnapshot {
        // `strategy show` deliberately returns 2 when the stored value is invalid.
        // Accept that status so the app can still offer a supported profile to repair it.
        let show = try run(["strategy", "show", "--json"], acceptedExitCodes: [0, 2])
        guard let data = show.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configured = json["strategy"] as? String else {
            throw serviceError(L("Unable to parse the current strategy.", "无法解析当前策略。"))
        }

        let routing = json["routing"] as? String
        let valid = (json["valid"] as? NSNumber)?.boolValue ?? false
        let profilesOutput = try run(["strategy", "profiles"])
        let profiles = parseProfiles(profilesOutput.stdout)
        guard !profiles.isEmpty else {
            throw serviceError(L("No strategy profiles were reported by codex-flow.", "codex-flow 未返回可用策略模式。"))
        }

        return StrategyModeSnapshot(
            configured: configured,
            routing: routing,
            valid: valid,
            profiles: profiles
        )
    }

    public static func set(_ profile: String) throws -> StrategyModeSnapshot {
        let before = try load()
        guard before.profiles.contains(where: { $0.name == profile }) else {
            throw serviceError(L("Unsupported strategy: \(profile)", "不支持的策略：\(profile)"))
        }

        _ = try run(["strategy", "set", profile])
        let verified = try load()
        guard verified.configured == profile, verified.valid else {
            throw serviceError(L("Strategy change could not be verified.", "策略切换后无法验证配置结果。"))
        }
        return verified
    }

    private struct CommandResult {
        let stdout: String
        let stderr: String
    }

    private static func run(
        _ arguments: [String],
        acceptedExitCodes: Set<Int32> = [0]
    ) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex")

        // FlowPilot is commonly launched by Finder or a login item, where the
        // process PATH does not include ~/.local/bin. Resolve the CLI locations
        // used by install.sh directly before falling back to PATH lookup.
        var candidates: [URL] = []
        if let configuredBinDir = environment["CODEX_FLOW_BIN_DIR"], !configuredBinDir.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredBinDir).appendingPathComponent("codex-flow"))
        }
        candidates.append(home.appendingPathComponent(".local/bin/codex-flow"))
        candidates.append(codexHome.appendingPathComponent("codex-flow/bin/codex-flow"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex-flow"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex-flow"))

        if let installedCLI = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            process.executableURL = installedCLI
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex-flow"] + arguments
        }

        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard acceptedExitCodes.contains(process.terminationStatus) else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw serviceError(detail.isEmpty
                ? L("codex-flow strategy command failed.", "codex-flow 策略命令执行失败。")
                : detail)
        }
        return CommandResult(stdout: stdout, stderr: stderr)
    }

    private static func parseProfiles(_ raw: String) -> [StrategyProfileInfo] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let pieces = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let first = pieces.first else { return nil }
            let name = String(first)
            let description = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
            return StrategyProfileInfo(name: name, description: description)
        }
    }

    private static func serviceError(_ message: String) -> NSError {
        NSError(domain: "FlowPilot.Strategy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public struct StrategyModeCard: View {
    @ObservedObject private var localization = AppLocalization.shared
    @State private var snapshot: StrategyModeSnapshot?
    @State private var isLoading = false
    @State private var applyingProfile: String?
    @State private var message: String?
    @State private var isError = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label(L("Global strategy mode", "全局策略模式"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                Spacer()
                if let snapshot {
                    if let routing = snapshot.routing, !routing.isEmpty {
                        Text(routing.uppercased())
                            .font(.system(size: 6.8, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.42))
                    }
                    Text(snapshot.configured.uppercased())
                        .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                        .foregroundColor(snapshot.valid ? .cyan : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((snapshot.valid ? Color.cyan : Color.orange).opacity(0.12)))
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.48))
                }
                .buttonStyle(.plain)
                .disabled(isLoading || applyingProfile != nil)
            }

            if isLoading && snapshot == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("Reading strategy…", "正在读取策略…"))
                        .font(.system(size: 8.5))
                        .foregroundColor(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            } else if let snapshot {
                if !snapshot.valid {
                    Text(L("The stored strategy is invalid. Choose a supported mode below to repair it.", "当前保存的策略无效，请在下方选择一个受支持模式进行修复。"))
                        .font(.system(size: 7.8, weight: .medium))
                        .foregroundColor(.orange.opacity(0.88))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(snapshot.profiles) { profile in
                        strategyButton(profile, current: snapshot.configured)
                    }
                }

                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 7.5))
                        .padding(.top, 1)
                    Text(L("This changes the global policy through `codex-flow strategy set`. A repository `.codex-flow.toml` remains higher priority for tasks in that repository.", "这里通过 `codex-flow strategy set` 修改全局策略；具体仓库中的 `.codex-flow.toml` 对该仓库任务仍具有更高优先级。"))
                        .font(.system(size: 7.5))
                }
                .foregroundColor(.white.opacity(0.35))

                if let message {
                    Text(message)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(isError ? .orange : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(message ?? L("Strategy data unavailable", "策略数据暂不可用"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.orange.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
        )
        .onAppear(perform: refresh)
    }

    private func strategyButton(_ profile: StrategyProfileInfo, current: String) -> some View {
        let selected = profile.name == current
        let pending = applyingProfile == profile.name
        return Button {
            apply(profile.name)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: profile.iconName)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(profile.accent)
                    Text(profile.localizedName)
                        .font(.system(size: 8.8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(selected ? 0.95 : 0.72))
                    Spacer()
                    if pending {
                        ProgressView().controlSize(.mini)
                    } else if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(profile.accent)
                    }
                }
                HoverRevealText(
                    profile.localizedDescription,
                    font: .system(size: 7.3),
                    foregroundColor: .white.opacity(0.38),
                    lineLimit: 2,
                    popoverWidth: 320
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? profile.accent.opacity(0.12) : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(selected ? profile.accent.opacity(0.45) : Color.white.opacity(0.055), lineWidth: 0.7)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(applyingProfile != nil || selected)
    }

    private func refresh() {
        guard !isLoading, applyingProfile == nil else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try StrategyModeService.load()
                DispatchQueue.main.async {
                    snapshot = value
                    message = nil
                    isError = false
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    message = error.localizedDescription
                    isError = true
                    isLoading = false
                }
            }
        }
    }

    private func apply(_ profile: String) {
        guard applyingProfile == nil else { return }
        applyingProfile = profile
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let verified = try StrategyModeService.set(profile)
                DispatchQueue.main.async {
                    snapshot = verified
                    applyingProfile = nil
                    isError = false
                    message = L("Global strategy switched to \(profile).", "全局策略已切换为 \(profile)。")
                }
            } catch {
                DispatchQueue.main.async {
                    applyingProfile = nil
                    isError = true
                    message = error.localizedDescription
                }
            }
        }
    }
}
