import SwiftUI
import Foundation
import Darwin

public struct FlowPilotAutostartStatus: Equatable {
    public let enabled: Bool
    public let plistExists: Bool
    public let launchdLoaded: Bool
    public let executablePath: String
}

public enum FlowPilotAutostartService {
    public static let label = "com.parsifalc.codex-flow.flowpilot"

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var codexHome: URL {
        environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex")
    }
    private static var stateDirectory: URL { codexHome.appendingPathComponent("codex-flow") }
    private static var preferenceURL: URL { stateDirectory.appendingPathComponent("autostart-preference") }
    private static var launchAgentsDirectory: URL { home.appendingPathComponent("Library/LaunchAgents") }
    private static var plistURL: URL { launchAgentsDirectory.appendingPathComponent("\(label).plist") }

    private static let userDefaultsKey = "FlowPilot.Autostart.Enabled"

    public static func status() -> FlowPilotAutostartStatus {
        // Status is intentionally read-only.  Re-registering a missing plist
        // here can bootstrap a RunAtLoad LaunchAgent while the app is merely
        // constructing its UI, which races the singleton owner.
        let pref = configuredPreference()
        let exists = FileManager.default.fileExists(atPath: plistURL.path)
        // A stored preference alone is not an active login registration.  A
        // missing plist is reported as disabled so toggling the control back
        // on explicitly recreates and bootstraps the LaunchAgent.
        let isEnabled = (pref ?? exists) && exists
        return FlowPilotAutostartStatus(
            enabled: isEnabled,
            plistExists: exists,
            launchdLoaded: launchdIsLoaded(),
            executablePath: resolvedExecutable().path
        )
    }

    @discardableResult
    public static func enable() throws -> FlowPilotAutostartStatus {
        try writePreference(enabled: true)
        try writeRegistration()
        return status()
    }

    @discardableResult
    public static func disable() throws -> FlowPilotAutostartStatus {
        try writePreference(enabled: false)
        // Deliberately do not `bootout` the current job here. If FlowPilot was
        // launched by launchd, booting it out would kill the app as the user
        // toggles the setting. Removing the plist is sufficient to prevent the
        // next login from launching it; uninstall performs a full bootout.
        try removeRegistration()
        return status()
    }

    private static func configuredPreference() -> Bool? {
        if let raw = try? String(contentsOf: preferenceURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch raw {
            case "enabled", "true", "1", "yes": return true
            case "disabled", "false", "0", "no": return false
            default: break
            }
        }
        if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: userDefaultsKey)
        }
        return nil
    }

    private static func writePreference(enabled: Bool) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try (enabled ? "enabled\n" : "disabled\n").write(to: preferenceURL, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }

    private static func writeRegistration() throws {
        let executable = resolvedExecutable()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw serviceError(L(
                "FlowPilot executable is not available for login launch.",
                "用于登录启动的 FlowPilot 可执行文件不存在。"
            ))
        }

        let logs = stateDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let path = [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")

        var launchEnvironment: [String: String] = ["PATH": path]
        // A RunAtLoad launch is best-effort reconciliation.  The app must not
        // preempt a manual/restart owner when launchd notices the plist.
        launchEnvironment[FlowPilotInstanceLock.launchAgentEnvironmentKey] = "1"
        if let configuredCodexHome = environment["CODEX_HOME"], !configuredCodexHome.isEmpty {
            launchEnvironment["CODEX_HOME"] = configuredCodexHome
        }
        if let configuredBinDir = environment["CODEX_FLOW_BIN_DIR"], !configuredBinDir.isEmpty {
            launchEnvironment["CODEX_FLOW_BIN_DIR"] = configuredBinDir
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "start"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": launchEnvironment,
            "StandardOutPath": logs.appendingPathComponent("flowpilot-launchd.out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("flowpilot-launchd.err.log").path
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = chmod(plistURL.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH))

        // Ensure launchd is aware of the LaunchAgent in the current GUI session
        if !launchdIsLoaded() {
            _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        }
    }

    private static func removeRegistration() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    private static func resolvedExecutable() -> URL {
        // Prefer the stable installer-managed location so a source checkout can
        // move without breaking login launch. Dev builds fall back to themselves.
        let installed = stateDirectory.appendingPathComponent("bin/FlowPilot")
        if FileManager.default.isExecutableFile(atPath: installed.path) {
            return installed
        }
        let legacy = stateDirectory.appendingPathComponent("bin/codex-flow-overlay")
        if FileManager.default.isExecutableFile(atPath: legacy.path) {
            return legacy
        }
        if let current = CommandLine.arguments.first, !current.isEmpty {
            let currentURL = URL(fileURLWithPath: current).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: currentURL.path) {
                return currentURL
            }
        }
        return installed
    }

    private static func launchdIsLoaded() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func serviceError(_ message: String) -> NSError {
        NSError(domain: "FlowPilot.Autostart", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public struct AutostartCard: View {
    @ObservedObject private var localization = AppLocalization.shared
    @State private var status: FlowPilotAutostartStatus?
    @State private var isChanging = false
    @State private var message: String?
    @State private var isError = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(status?.enabled == true ? .green : .orange.opacity(0.72))

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Launch at Login", "登录时启动"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.84))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()

                if isChanging || status == nil {
                    ProgressView().controlSize(.mini)
                }

                Toggle(L("Launch at Login", "登录时启动"), isOn: Binding(
                    get: { status?.enabled ?? false },
                    set: { setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(SleekSwitchToggleStyle(tint: .green))
                .disabled(isChanging || status == nil)
            }

            if let message {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isError ? .orange : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text(L(
                    "Starts FlowPilot at your next login. The current window stays open.",
                    "下次登录时自动打开 FlowPilot，不影响当前窗口。"
                ))
                    .font(.system(size: 11))
            }
            .foregroundColor(.white.opacity(0.55))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
        )
        .onAppear(perform: refresh)
    }

    private var statusText: String {
        guard let status else { return L("Reading login settings…", "正在读取登录设置…") }
        guard status.enabled else { return L("Disabled", "已关闭") }
        if status.launchdLoaded {
            return L("Enabled · starts with your Mac", "已开启 · 登录后自动启动")
        }
        return L("Enabled · starts automatically on next login", "已开启 · 下次登录自动启动")
    }

    private func refresh() {
        guard !isChanging else { return }
        isChanging = true
        // Waiting for launchctl during SwiftUI layout can reenter its graph
        // through Process.waitUntilExit's run loop and abort the application.
        DispatchQueue.global(qos: .userInitiated).async {
            let next = FlowPilotAutostartService.status()
            DispatchQueue.main.async {
                status = next
                isChanging = false
            }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        isChanging = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let next = try enabled
                    ? FlowPilotAutostartService.enable()
                    : FlowPilotAutostartService.disable()
                DispatchQueue.main.async {
                    status = next
                    isChanging = false
                    isError = false
                    message = enabled
                        ? L("FlowPilot will launch automatically when you next log in.", "FlowPilot 将在下次登录时自动启动。")
                        : L("Login launch disabled; FlowPilot remains running now.", "已关闭登录启动；当前 FlowPilot 继续运行。")
                }
            } catch {
                let next = FlowPilotAutostartService.status()
                DispatchQueue.main.async {
                    status = next
                    isChanging = false
                    isError = true
                    message = error.localizedDescription
                }
            }
        }
    }
}
