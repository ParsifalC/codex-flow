import Cocoa
import SwiftUI
import Combine

// MARK: - Shared Observable State
public class OverlayState: ObservableObject {
    @Published public var isExpanded: Bool = false
    @Published public var isPinned: Bool = false
    @Published public var isTaskRunning: Bool = false
    @Published public var latestRun: TaskRun? = nil
    
    public weak var windowController: OverlayWindowController?
    
    public init() {}
    
    public func expand() {
        guard !isExpanded else { return }
        DispatchQueue.main.async {
            self.isExpanded = true
            self.windowController?.updateWindowFrame(animated: true)
        }
    }
    
    public func collapse() {
        guard isExpanded else { return }
        DispatchQueue.main.async {
            self.isExpanded = false
            self.isPinned = false
            self.windowController?.updateWindowFrame(animated: true)
        }
    }
    
    public func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }
    
    public func update(run: TaskRun) {
        DispatchQueue.main.async {
            self.latestRun = run
            self.isTaskRunning = run.isRunning
            // Update window frame size if expanded to accommodate new data
            if self.isExpanded {
                self.windowController?.updateWindowFrame(animated: true)
            }
        }
    }
}

// MARK: - Main Root Container View
public struct OverlayRootView: View {
    @ObservedObject var state: OverlayState
    
    public init(state: OverlayState) {
        self.state = state
    }
    
    public var body: some View {
        ZStack(alignment: .topTrailing) {
            if state.isExpanded {
                SummaryView(state: state)
                    .frame(width: 376)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing))
                        )
                    )
            } else {
                BubbleView(state: state)
                    .frame(width: 76, height: 76)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing))
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(Color.clear)
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: state.isExpanded)
    }
}

// MARK: - Custom Tracking Hosting View
class TrackingHostingView<Content: View>: NSHostingView<Content> {
    weak var windowController: OverlayWindowController?
    private var trackingArea: NSTrackingArea?
    
    required public init(rootView: Content) {
        super.init(rootView: rootView)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.isOpaque = false
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.isOpaque = false
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        windowController?.handleMouseEntered()
    }
    
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        windowController?.handleMouseMoved()
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        windowController?.handleMouseExited()
    }
    
    // Dragging support
    private var initialLocation: NSPoint = .zero
    
    override func mouseDown(with event: NSEvent) {
        initialLocation = event.locationInWindow
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window else { return }
        let currentLocation = event.locationInWindow
        let deltaX = currentLocation.x - initialLocation.x
        let deltaY = currentLocation.y - initialLocation.y
        
        var newOrigin = window.frame.origin
        newOrigin.x += deltaX
        newOrigin.y += deltaY
        
        // Clamp to screen bounds
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            newOrigin.x = max(visible.minX, min(newOrigin.x, visible.maxX - window.frame.width))
            newOrigin.y = max(visible.minY, min(newOrigin.y, visible.maxY - window.frame.height))
        }
        
        window.setFrameOrigin(newOrigin)
        windowController?.saveWindowPosition(newOrigin)
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        
        if let state = windowController?.state {
            if state.isExpanded {
                let pinItem = NSMenuItem(
                    title: state.isPinned ? "Unpin Window" : "Pin Window",
                    action: #selector(togglePin),
                    keyEquivalent: "p"
                )
                pinItem.target = self
                menu.addItem(pinItem)
                
                let collapseItem = NSMenuItem(
                    title: "Collapse to Bubble",
                    action: #selector(collapseBubble),
                    keyEquivalent: "c"
                )
                collapseItem.target = self
                menu.addItem(collapseItem)
            } else {
                let expandItem = NSMenuItem(
                    title: "Expand Summary",
                    action: #selector(expandSummary),
                    keyEquivalent: "e"
                )
                expandItem.target = self
                menu.addItem(expandItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let consoleItem = NSMenuItem(
            title: "Open Codex Console",
            action: #selector(openConsole),
            keyEquivalent: "t"
        )
        consoleItem.target = self
        menu.addItem(consoleItem)
        
        let refreshItem = NSMenuItem(
            title: "Refresh Telemetry",
            action: #selector(refreshData),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(
            title: "Quit Floating Widget",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    
    @objc private func togglePin() {
        windowController?.state.isPinned.toggle()
    }
    
    @objc private func expandSummary() {
        windowController?.state.expand()
    }
    
    @objc private func collapseBubble() {
        windowController?.state.collapse()
    }
    
    @objc private func openConsole() {
        let script = """
        tell application "Terminal"
            activate
            do script "codex-flow"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
    
    @objc private func refreshData() {
        windowController?.refreshTelemetry()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Overlay Window Controller
public class OverlayWindowController: NSObject, NSWindowDelegate {
    public let state: OverlayState
    public var window: NSPanel!
    
    private var hoverDwellTimer: Timer?
    private var collapseTimer: Timer?
    private let bubbleSize = NSSize(width: 76, height: 76)
    private let summarySize = NSSize(width: 376, height: 420)
    
    public init(state: OverlayState) {
        self.state = state
        super.init()
        state.windowController = self
        setupWindow()
    }
    
    private func setupWindow() {
        let initialRect = loadSavedPosition() ?? defaultPosition(for: bubbleSize)
        
        window = NSPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.level = .floating
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.delegate = self
        
        let rootView = OverlayRootView(state: state)
        let hostingView = TrackingHostingView(rootView: rootView)
        hostingView.windowController = self
        window.contentView = hostingView
        
        window.orderFront(nil)
    }
    
    // MARK: - Hover-Dwell 0.4s Detection
    public func handleMouseEntered() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        
        guard !state.isExpanded else { return }
        resetDwellTimer()
    }
    
    public func handleMouseMoved() {
        guard !state.isExpanded else { return }
        resetDwellTimer()
    }
    
    private func resetDwellTimer() {
        hoverDwellTimer?.invalidate()
        // Dwell requirement: cursor stops moving for 0.4 second on the bubble
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, !self.state.isExpanded else { return }
            self.state.expand()
        }
    }
    
    public func handleMouseExited() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
        
        // Auto-collapse after grace period if expanded and not pinned
        if state.isExpanded && !state.isPinned {
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self = self, self.state.isExpanded, !self.state.isPinned else { return }
                self.state.collapse()
            }
        }
    }
    
    // MARK: - Frame Resizing & Animation
    public func updateWindowFrame(animated: Bool = true) {
        guard let window = self.window else { return }
        let targetSize = state.isExpanded ? summarySize : bubbleSize
        let currentFrame = window.frame
        
        // Keep top-right corner stable during expand/collapse
        var newOrigin = NSPoint(
            x: currentFrame.maxX - targetSize.width,
            y: currentFrame.maxY - targetSize.height
        )
        
        // Clamp to screen bounds
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            newOrigin.x = max(visible.minX, min(newOrigin.x, visible.maxX - targetSize.width))
            newOrigin.y = max(visible.minY, min(newOrigin.y, visible.maxY - targetSize.height))
        }
        
        let newFrame = NSRect(origin: newOrigin, size: targetSize)
        
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true)
        }
    }
    
    // MARK: - Position Persistence
    private let positionKey = "CodexFlowOverlayWindowPosition"
    
    public func saveWindowPosition(_ origin: NSPoint) {
        let dict: [String: Double] = ["x": Double(origin.x), "y": Double(origin.y)]
        UserDefaults.standard.set(dict, forKey: positionKey)
    }
    
    private func loadSavedPosition() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: positionKey) as? [String: Double],
              let x = dict["x"], let y = dict["y"] else {
            return nil
        }
        return NSRect(x: CGFloat(x), y: CGFloat(y), width: bubbleSize.width, height: bubbleSize.height)
    }
    
    private func defaultPosition(for size: NSSize) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.maxX - size.width - 32
        let y = screen.maxY - size.height - 32
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
    
    public func refreshTelemetry() {
        // Will be triggered by watcher or manual refresh
    }
}
