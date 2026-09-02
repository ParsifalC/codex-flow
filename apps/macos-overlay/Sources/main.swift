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
    codex-flow-overlay - Native macOS Floating Window for FlowPilot / Codex Telemetry

    Usage:
      codex-flow-overlay [command]

    Commands:
      start, --daemon    Start the floating overlay daemon (default)
      stop, quit         Stop running overlay daemon
      status             Check if overlay daemon is currently active
      toggle             Toggle between circular bubble and expanded summary
      expand             Expand summary window
      collapse           Collapse to circular bubble
      update <path|json> Push a telemetry run update and expand
      help, -h           Show this help message
    """)
}

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args[0] == "start" || args[0] == "--daemon" {
    // Check if already running
    let statusCheck = IPCService.sendCommand("status")
    if statusCheck.success {
        print("codex-flow-overlay is already running.")
        exit(0)
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
            print("● Overlay is RUNNING: \(res.response)")
            exit(0)
        } else {
            print("○ Overlay is NOT running.")
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
