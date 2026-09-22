import Cocoa
import SwiftUI

public final class ConversationAnalysisWindowController: NSWindowController, NSWindowDelegate {
    public let service: ConversationAnalysisService

    public init(service: ConversationAnalysisService) {
        self.service = service
        let content = ConversationAnalysisPreview(service: service)
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "FlowPilot · " + L("Conversation Analysis Preview", "对话分析预览")
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showPreview() {
        NSApp.setActivationPolicy(.regular)
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        service.stop()
        NSApp.terminate(nil)
    }
}

private final class ConversationAnalysisPreviewAppDelegate: NSObject, NSApplicationDelegate {
    private let configuration: AnalysisPreviewConfiguration
    private var controller: ConversationAnalysisWindowController?

    init(configuration: AnalysisPreviewConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = ConversationAnalysisService(configuration: configuration)
        let controller = ConversationAnalysisWindowController(service: service)
        self.controller = controller
        controller.showPreview()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.service.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
