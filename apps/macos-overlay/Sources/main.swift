import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var state: OverlayState!
    var windowController: OverlayWindowController!
    var watcher: TelemetryWatcher!
    var ipcServer: IPCService.Server!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
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
    print("""
    FlowPilot - Native macOS Assistant & Telemetry Widget

    Usage:
      FlowPilot [command] [options]

    Commands:
      start, --daemon           Start/Restart the FlowPilot floating daemon (default)
      restart                   Restart the running FlowPilot daemon with fresh build
      stop, quit                Stop running FlowPilot daemon
      status                    Check if FlowPilot daemon is currently active
      toggle                    Toggle between circular bubble and expanded summary
      expand                    Expand summary window
      collapse                  Collapse to circular bubble
      tab <inspector|hist|stat> Switch active tab in expanded view
      show <#|id|session>       Inspect specific task in FlowPilot
      stats [days]              Open analytics dashboard with N days (default: 30)
      history, list             Open history task timeline
      update [path|json]        Push telemetry run update and expand
      help, -h                  Show this help message
    """)
}

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args[0] == "start" || args[0] == "--daemon" || args[0] == "restart" {
    // If an older instance is already running, cleanly terminate it first so new code runs
    let statusCheck = IPCService.sendCommand("status")
    if statusCheck.success {
        _ = IPCService.sendCommand("quit")
        usleep(250_000) // 250ms for socket cleanup
    }
    
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
} else {
    let cmd = args[0]
    switch cmd {
    case "status":
        let res = IPCService.sendCommand("status")
        if res.success {
            print("● FlowPilot is RUNNING: \(res.response)")
            exit(0)
        } else {
            print("○ FlowPilot is NOT running.")
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
        print("Unknown command: \(cmd)")
        printUsage()
        exit(1)
    }
}
