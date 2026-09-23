import Cocoa
import SwiftUI

private final class ConversationAnalysisPreviewAppDelegate: NSObject, NSApplicationDelegate {
    private let configuration: AnalysisPreviewConfiguration
    private var controller: OverlayWindowController?
    private var state: OverlayState?
    private var watcher: TelemetryWatcher?

    init(configuration: AnalysisPreviewConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = ConversationAnalysisService(configuration: configuration)
        let state = OverlayState()
        self.state = state
        state.attachAnalysis(service)
        let controller = OverlayWindowController(state: state)
        self.controller = controller
        // Observe the existing telemetry without running recovery writes from a preview.
        watcher = TelemetryWatcher(state: state, recoveryRunner: { _ in })
        controller.window.title = "FlowPilot"
        state.isPinned = true
        state.expand()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stopWatching()
        state?.analysisService?.stop()
        state?.stopPet()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The overlay is an NSPanel; closing NSSavePanel must not quit the app.
        false
    }
}

public enum ConversationAnalysisPreviewApplication {
    public static func run(arguments: [String]) throws {
        let launch = try AnalysisPreviewLaunchArguments(arguments: arguments)
        let configuration = try launch.configuration.validated()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ConversationAnalysisPreviewAppDelegate(configuration: configuration)
        app.delegate = delegate
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: L("Quit Preview", "退出预览"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application)
        let edit = NSMenuItem(title: L("Edit", "编辑"), action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: edit.title)
        for (title, action, key) in [(L("Cut", "剪切"), "cut:", "x"), (L("Copy", "复制"), "copy:", "c"), (L("Paste", "粘贴"), "paste:", "v"), (L("Select All", "全选"), "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    }
}
