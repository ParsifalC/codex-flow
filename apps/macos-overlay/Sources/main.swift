import Cocoa
import SwiftUI
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    var state: OverlayState!
    var windowController: OverlayWindowController!
    var watcher: TelemetryWatcher!
    var ipcServer: IPCService.Server!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Reconcile user-configured autostart registration if previously enabled.
        FlowPilotAutostartService.reconcileIfNeeded()

        state = OverlayState()
        windowController = OverlayWindowController(state: state)
        watcher = TelemetryWatcher(state: state)
        ipcServer = IPCService.Server(state: state)
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stopWatching()
        ipcServer?.stop()
    }
}

func printUsage() {
    print(L(
        """
        FlowPilot - Native macOS Assistant & Telemetry Widget

        Usage:
          FlowPilot [command] [options]

        Commands:
          start, --daemon           Start/Restart the FlowPilot floating daemon (default)
          restart                   Restart the running FlowPilot daemon with fresh build
          stop, quit                Stop running FlowPilot daemon
          status [--json]           Check if FlowPilot daemon is currently active
          autostart [action]        Login launch: status|enable|disable
          toggle                    Toggle between circular bubble and expanded summary
          expand                    Expand summary window
          collapse                  Collapse to circular bubble
          tab <inspector|hist|stat> Switch active tab in expanded view
          show <#|id|session>       Inspect specific task in FlowPilot
          stats [days]              Open analytics dashboard with N days (default: 30)
          history, list             Open history task timeline
          update [path|json]        Push telemetry run update and expand
          help, -h                  Show this help message
        """,
        """
        FlowPilot - macOS 原生助手与遥测悬浮窗

        用法：
          FlowPilot [命令] [选项]

        命令：
          start, --daemon           启动/重启 FlowPilot 悬浮窗（默认）
          restart                   使用最新构建重启 FlowPilot
          stop, quit                停止 FlowPilot
          status [--json]           查看 FlowPilot 是否正在运行
          autostart [操作]          登录启动：status|enable|disable
          toggle                    在悬浮球与展开摘要之间切换
          expand                    展开摘要窗口
          collapse                  收起为悬浮球
          tab <inspector|hist|stat> 切换展开视图中的标签页
          show <#|id|session>       查看指定任务
          stats [days]              打开 N 天统计面板（默认：30）
          history, list             打开历史任务列表
          update [path|json]        推送遥测任务更新并展开
          help, -h                  显示帮助
        """
    ))
}

func printAutostartStatus(_ status: FlowPilotAutostartStatus, json: Bool) {
    if json {
        let object: [String: Any] = [
            "enabled": status.enabled,
            "registered": status.plistExists,
            "launchdLoaded": status.launchdLoaded,
            "executable": status.executablePath
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }

    if status.enabled {
        let detail = status.launchdLoaded
            ? L("launchd loaded in this login session", "当前登录会话已由 launchd 加载")
            : L("registered for the next login", "已注册，将在下次登录时启动")
        print(L("● Login launch enabled · \(detail)", "● 登录启动已开启 · \(detail)"))
    } else {
        print(L("○ Login launch disabled", "○ 登录启动已关闭"))
    }
}

func printStatusFailureJSON(_ message: String) {
    let object: [String: Any] = ["running": false, "error": message]
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func writeStandardError(_ message: String) {
    guard let data = message.data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

func waitForPreviousInstanceToReleaseSocket(timeout: TimeInterval = 3.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while FileManager.default.fileExists(atPath: IPCService.socketPath) {
        let probe = IPCService.sendCommand("status")
        if !probe.success || !probe.response.contains("\"running\": true") {
            // A process can exit before its dispatch-source cancel handler gets
            // enough runtime to unlink the filesystem socket. At this point no
            // server answers the endpoint, so removing the stale node is safe.
            try? FileManager.default.removeItem(atPath: IPCService.socketPath)
            return !FileManager.default.fileExists(atPath: IPCService.socketPath)
        }
        if Date() >= deadline {
            return false
        }
        usleep(20_000)
    }
    return true
}

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args[0] == "start" || args[0] == "--daemon" || args[0] == "restart" {
    // Detach from controlling terminal session and ignore hangup signals when running as daemon
    _ = setsid()
    signal(SIGHUP, SIG_IGN)

    // If an older instance is already running, cleanly terminate it and wait for
    // its IPC endpoint to be released before binding a replacement. A fixed sleep
    // can let the old shutdown race the new bind and delete the new socket.
    let statusCheck = IPCService.sendCommand("status")
    if statusCheck.success {
        _ = IPCService.sendCommand("quit")
        if !waitForPreviousInstanceToReleaseSocket() {
            writeStandardError(L(
                "FlowPilot restart timed out waiting for the previous IPC socket to close.\n",
                "FlowPilot 重启等待旧 IPC socket 关闭超时。\n"
            ))
            exit(1)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
} else {
    let cmd = args[0]
    switch cmd {
    case "status":
        let wantsJSON = args.contains("--json")
        let res = IPCService.sendCommand("status")
        if res.success {
            if wantsJSON {
                print(res.response)
            } else {
                print(L("● FlowPilot is RUNNING: \(res.response)", "● FlowPilot 正在运行：\(res.response)"))
            }
            exit(0)
        } else {
            if wantsJSON {
                printStatusFailureJSON(res.response)
            } else {
                print(L("○ FlowPilot is NOT running.", "○ FlowPilot 未运行。"))
            }
            exit(1)
        }
    case "autostart":
        let action = args.count > 1 ? args[1].lowercased() : "status"
        let wantsJSON = args.contains("--json")
        do {
            switch action {
            case "status":
                printAutostartStatus(FlowPilotAutostartService.status(), json: wantsJSON)
            case "enable", "on":
                let status = try FlowPilotAutostartService.enable()
                printAutostartStatus(status, json: wantsJSON)
            case "disable", "off":
                let status = try FlowPilotAutostartService.disable()
                printAutostartStatus(status, json: wantsJSON)
            default:
                print(L(
                    "Usage: FlowPilot autostart status|enable|disable [--json]",
                    "用法：FlowPilot autostart status|enable|disable [--json]"
                ))
                exit(2)
            }
            exit(0)
        } catch {
            if wantsJSON {
                let object: [String: Any] = ["error": error.localizedDescription]
                if let data = try? JSONSerialization.data(withJSONObject: object),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
            } else {
                print(L("Autostart update failed: \(error.localizedDescription)", "登录启动设置失败：\(error.localizedDescription)"))
            }
            exit(1)
        }
    case "toggle":
        let res = IPCService.sendCommand("toggle")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "expand":
        let res = IPCService.sendCommand("expand")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "collapse":
        let res = IPCService.sendCommand("collapse")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "tab":
        let target = args.dropFirst().joined(separator: " ")
        let res = IPCService.sendCommand("tab \(target)")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "show":
        let target = args.dropFirst().joined(separator: " ")
        let res = IPCService.sendCommand("show \(target)")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "stats", "summary":
        let target = args.dropFirst().joined(separator: " ")
        let res = IPCService.sendCommand("stats \(target)")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "history", "list":
        let res = IPCService.sendCommand("history")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "stop", "quit":
        let res = IPCService.sendCommand("quit")
        print(res.response)
        exit(res.success ? 0 : 1)
    case "update":
        let payload = args.dropFirst().joined(separator: " ")
        if payload.isEmpty {
            let res = IPCService.sendCommand("update")
            print(res.response)
            exit(res.success ? 0 : 1)
        } else {
            let res = IPCService.sendCommand("update \(payload)")
            print(res.response)
            exit(res.success ? 0 : 1)
        }
    case "help", "-h", "--help":
        printUsage()
        exit(0)
    default:
        print(L("Unknown command: \(cmd)", "未知命令：\(cmd)"))
        printUsage()
        exit(1)
    }
}
