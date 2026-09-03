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
    public let enabled: Bool
    public let configured: String
    public let routing: String?
    public let valid: Bool
    public let profiles: [StrategyProfileInfo]
}

private final class StrategyCommandCapture {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
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

        let enabled = (json["enabled"] as? NSNumber)?.boolValue ?? true
        let routing = json["routing"] as? String
        let valid = (json["valid"] as? NSNumber)?.boolValue ?? false
        let profilesOutput = try run(["strategy", "profiles"])
        let profiles = parseProfiles(profilesOutput.stdout)
        guard !profiles.isEmpty else {
            throw serviceError(L("No strategy profiles were reported by codex-flow.", "codex-flow 未返回可用策略模式。"))
        }

        return StrategyModeSnapshot(
            enabled: enabled,
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

    public static func setEnabled(_ enabled: Bool) throws -> StrategyModeSnapshot {
        _ = try run(["strategy", enabled ? "enable" : "disable"])
        let verified = try load()
        guard verified.enabled == enabled else {
            throw serviceError(L(
                "Strategy master switch change could not be verified.",
                "策略总开关修改后无法验证配置结果。"
            ))
        }
        return verified
    }

    public static func armTemporaryBypass() throws {
        _ = try run(["strategy", "bypass-once"])
        let pending = try run(["strategy", "bypass-pending"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending == "true" else {
            throw serviceError(L(
                "Temporary strategy bypass could not be verified.",
                "临时关闭策略分发后无法验证一次性状态。"
            ))
        }
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

        let stdoutCapture = StrategyCommandCapture()
        let stderrCapture = StrategyCommandCapture()
        let stdoutEOF = DispatchSemaphore(value: 0)
        let stderrEOF = DispatchSemaphore(value: 0)

        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutEOF.signal()
            } else {
                stdoutCapture.append(data)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrEOF.signal()
            } else {
                stderrCapture.append(data)
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        process.waitUntilExit()

        // stdout/stderr are drained concurrently while the process runs, so a
        // verbose child cannot fill a pipe and deadlock waitUntilExit(). Give
        // the EOF callbacks a bounded moment to flush their final chunks.
        _ = stdoutEOF.wait(timeout: .now() + 1.0)
        _ = stderrEOF.wait(timeout: .now() + 1.0)

        let stdout = stdoutCapture.string()
        let stderr = stderrCapture.string()
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
    @State private var applyingEnabled = false
    @State private var showDisableConfirmation = false
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
                        Text(localizedRoutingName(routing))
                            .font(.system(size: 6.8, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.42))
                    }
                    Text(localizedConfiguredName(snapshot))
                        .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                        .foregroundColor(statusColor(snapshot))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(statusColor(snapshot).opacity(0.12)))
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.48))
                }
                .buttonStyle(.plain)
                .disabled(isLoading || applyingProfile != nil || applyingEnabled)
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
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Enable strategy dispatch", "启用策略分发"))
                            .font(.system(size: 8.8, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.84))
                        Text(L(
                            "Turn off FlowPilot automatic planning and Worker dispatch while keeping the selected profile.",
                            "关闭 FlowPilot 自动策略规划和 Worker 分发，同时保留当前策略配置。"
                        ))
                        .font(.system(size: 7.2))
                        .foregroundColor(.white.opacity(0.36))
                    }
                    Spacer()
                    if applyingEnabled {
                        ProgressView().controlSize(.mini)
                    }
                    Toggle("", isOn: strategyEnabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(isLoading || applyingProfile != nil || applyingEnabled)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.025)))

                if !snapshot.valid {
                    Text(L("The stored strategy is invalid. Choose a supported mode below to repair it.", "当前保存的策略无效，请在下方选择一个受支持模式进行修复。"))
                        .font(.system(size: 7.8, weight: .medium))
                        .foregroundColor(.orange.opacity(0.88))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(snapshot.profiles) { profile in
                        strategyButton(profile, current: snapshot.configured, enabled: snapshot.enabled)
                    }
                }
                .opacity(snapshot.enabled ? 1 : 0.42)

                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 7.5))
                        .padding(.top, 1)
                    Text(L("The master switch has global priority. When enabled, repository `.codex-flow.toml` may still override profile/routing; when disabled, repository policy cannot re-enable automatic dispatch.", "总开关具有全局最高优先级。开启时，仓库 `.codex-flow.toml` 仍可覆盖 profile/routing；关闭时，仓库策略不能重新开启自动分发。"))
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
        .confirmationDialog(
            L("Keep strategy dispatch available?", "要关闭策略分发吗？"),
            isPresented: $showDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("Temporary — next task only", "临时关闭 · 仅下一次任务")) {
                armTemporaryBypass()
            }
            Button(L("Permanently disable", "永久关闭"), role: .destructive) {
                applyEnabled(false)
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L(
                "If you only want one task to run without FlowPilot distribution, use Temporary. Strategy dispatch will automatically return for the task after that.",
                "如果只是想让下一次任务不经过 FlowPilot 分发，建议选择临时关闭；该任务消费后会自动恢复策略分发。"
            ))
        }
    }

    private var strategyEnabledBinding: Binding<Bool> {
        Binding(
            get: { snapshot?.enabled ?? true },
            set: { requested in
                if requested {
                    applyEnabled(true)
                } else if snapshot?.enabled == true {
                    showDisableConfirmation = true
                }
            }
        )
    }

    private func statusColor(_ snapshot: StrategyModeSnapshot) -> Color {
        guard snapshot.enabled else { return .white.opacity(0.45) }
        return snapshot.valid ? .cyan : .orange
    }

    private func localizedConfiguredName(_ snapshot: StrategyModeSnapshot) -> String {
        guard snapshot.enabled else { return L("Off", "已关闭") }
        return snapshot.profiles.first(where: { $0.name == snapshot.configured })?.localizedName
            ?? snapshot.configured.capitalized
    }

    private func localizedRoutingName(_ routing: String) -> String {
        switch routing.lowercased() {
        case "adaptive": return L("Adaptive", "自适应")
        case "direct": return L("Direct", "直接")
        case "delegate": return L("Delegate", "委派")
        default: return routing.capitalized
        }
    }

    private func strategyButton(_ profile: StrategyProfileInfo, current: String, enabled: Bool) -> some View {
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
        .disabled(applyingProfile != nil || applyingEnabled || !enabled || selected)
    }

    private func refresh() {
        guard !isLoading, applyingProfile == nil, !applyingEnabled else { return }
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
        guard applyingProfile == nil, !applyingEnabled else { return }
        applyingProfile = profile
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let verified = try StrategyModeService.set(profile)
                DispatchQueue.main.async {
                    snapshot = verified
                    applyingProfile = nil
                    isError = false
                    let displayName = verified.profiles.first(where: { $0.name == profile })?.localizedName ?? profile
                    message = L("Global strategy switched to \(displayName).", "全局策略已切换为 \(displayName)。")
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

    private func armTemporaryBypass() {
        guard !applyingEnabled, applyingProfile == nil else { return }
        applyingEnabled = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try StrategyModeService.armTemporaryBypass()
                DispatchQueue.main.async {
                    applyingEnabled = false
                    isError = false
                    message = L(
                        "Strategy dispatch will be skipped for the next task only.",
                        "已临时关闭：仅下一次任务跳过策略分发，之后自动恢复。"
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    applyingEnabled = false
                    isError = true
                    message = error.localizedDescription
                }
            }
        }
    }

    private func applyEnabled(_ enabled: Bool) {
        guard !applyingEnabled, applyingProfile == nil else { return }
        applyingEnabled = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let verified = try StrategyModeService.setEnabled(enabled)
                DispatchQueue.main.async {
                    snapshot = verified
                    applyingEnabled = false
                    isError = false
                    message = enabled
                        ? L("Strategy dispatch enabled.", "策略分发已开启。")
                        : L("Strategy dispatch disabled. FlowPilot will use ordinary Codex execution.", "策略分发已关闭，FlowPilot 将使用普通 Codex 执行。")
                }
            } catch {
                DispatchQueue.main.async {
                    applyingEnabled = false
                    isError = true
                    message = error.localizedDescription
                }
            }
        }
    }
}
