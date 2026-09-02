import Cocoa
import SwiftUI
import Combine

public enum DockEdge: String, Codable {
    case none
    case left
    case right
}

// MARK: - Shared Observable State
public class OverlayState: ObservableObject {
    @Published public var isExpanded: Bool = false
    @Published public var isPinned: Bool = false
    @Published public var isTaskRunning: Bool = false
    @Published public var isDocked: Bool = false
    @Published public var dockEdge: DockEdge = .right
    @Published public var latestRun: TaskRun? = nil
    
    // Tab & Explorer State
    @Published public var activeTab: OverlayTab = .inspector
    @Published public var inspectedRun: TaskRun? = nil
    @Published public var historyRuns: [TaskRun] = []
    @Published public var historyChats: [ChatSession] = []
    @Published public var expandedChatIds: Set<String> = []
    @Published public var statsData: TelemetryStats? = nil
    @Published public var statsDays: Int = 30
    @Published public var selectedProject: String? = nil
    @Published public var isTodayOnly: Bool = false
    @Published public var searchQuery: String = ""
    
    public weak var windowController: OverlayWindowController?
    
    public init() {
        if let latest = TelemetryQueryEngine.shared.loadLatestRun() {
            self.latestRun = latest
            self.isTaskRunning = latest.isRunning
        }
    }
    
    public func expand() {
        guard !isExpanded else { return }
        DispatchQueue.main.async {
            self.isDocked = false
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
            self.windowController?.scheduleTuck()
        }
    }
    
    public func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }
    
    public func selectTab(_ tab: OverlayTab) {
        DispatchQueue.main.async {
            self.activeTab = tab
            if tab == .history {
                self.loadHistory()
            } else if tab == .analytics {
                self.loadStats()
            }
            self.windowController?.updateWindowFrame(animated: true)
        }
    }
    
    public func inspect(run: TaskRun) {
        DispatchQueue.main.async {
            self.inspectedRun = run
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
        }
    }
    
    public func jumpToLive() {
        DispatchQueue.main.async {
            self.inspectedRun = nil
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
        }
    }
    
    public func toggleChatExpansion(_ id: String) {
        if expandedChatIds.contains(id) {
            expandedChatIds.remove(id)
        } else {
            expandedChatIds.insert(id)
        }
        self.windowController?.updateWindowFrame(animated: true)
    }
    
    public func isChatExpanded(_ id: String) -> Bool {
        return expandedChatIds.contains(id)
    }
    
    public func expandAllChats() {
        let allIds = historyChats.map { $0.sessionId }
        expandedChatIds = Set(allIds)
        self.windowController?.updateWindowFrame(animated: true)
    }
    
    public func collapseAllChats() {
        expandedChatIds.removeAll()
        self.windowController?.updateWindowFrame(animated: true)
    }
    
    public func loadHistory() {
        let proj = self.selectedProject
        let today = self.isTodayOnly
        let search = self.searchQuery
        DispatchQueue.global(qos: .userInitiated).async {
            let chats = TelemetryQueryEngine.shared.fetchChatHistory(
                limit: 60,
                project: proj,
                todayOnly: today,
                search: search
            )
            let runs = TelemetryQueryEngine.shared.fetchHistory(
                limit: 60,
                project: proj,
                todayOnly: today,
                search: search
            )
            DispatchQueue.main.async {
                self.historyChats = chats
                self.historyRuns = runs
                // Auto-expand first chat if none expanded and chats available
                if self.expandedChatIds.isEmpty, let first = chats.first {
                    self.expandedChatIds.insert(first.sessionId)
                }
            }
        }
    }
    
    public func loadStats() {
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = TelemetryQueryEngine.shared.computeStats(
                days: self.statsDays,
                project: self.selectedProject
            )
            DispatchQueue.main.async {
                self.statsData = stats
            }
        }
    }
    
    public func update(run: TaskRun) {
        DispatchQueue.main.async {
            self.latestRun = run
            self.isTaskRunning = run.isRunning
            // Refresh history/stats if in those tabs
            if self.activeTab == .history {
                self.loadHistory()
            } else if self.activeTab == .analytics {
                self.loadStats()
            }
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
                    .frame(width: 384)
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
        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: state.isExpanded)
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
    
    // MARK: - Dragging & Magnetic Edge Snapping
    private var initialLocation: NSPoint = .zero
    private var isDragging: Bool = false
    private let snapMargin: CGFloat = 8.0
    private let snapThreshold: CGFloat = 36.0
    
    override func mouseDown(with event: NSEvent) {
        initialLocation = event.locationInWindow
        isDragging = false
        windowController?.cancelDwellTimer()
        windowController?.isInteractingOrDragging = true
        super.mouseDown(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window else {
            super.mouseDragged(with: event)
            return
        }
        let currentLocation = event.locationInWindow
        let deltaX = currentLocation.x - initialLocation.x
        let deltaY = currentLocation.y - initialLocation.y
        let dragThreshold: CGFloat = (windowController?.state.isExpanded ?? false) ? 8.0 : 4.0
        if abs(deltaX) > dragThreshold || abs(deltaY) > dragThreshold {
            isDragging = true
            windowController?.cancelDwellTimer()
            windowController?.isInteractingOrDragging = true
            
            var newOrigin = window.frame.origin
            newOrigin.x += deltaX
            newOrigin.y += deltaY
            
            // Clamp to screen bounds during live drag
            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                newOrigin.x = max(visible.minX, min(newOrigin.x, visible.maxX - window.frame.width))
                newOrigin.y = max(visible.minY, min(newOrigin.y, visible.maxY - window.frame.height))
            }
            
            window.setFrameOrigin(newOrigin)
        } else {
            super.mouseDragged(with: event)
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        guard let window = self.window else {
            super.mouseUp(with: event)
            return
        }
        
        if isDragging {
            performMagneticSnap(for: window)
            // Suppress hover-expand briefly after dropping
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.windowController?.isInteractingOrDragging = false
            }
        } else {
            windowController?.isInteractingOrDragging = false
            // Only clicking on the collapsed circular bubble should trigger expand.
            // When already expanded, interactive clicks belong to SwiftUI tabs/buttons.
            if let state = windowController?.state, !state.isExpanded {
                state.expand()
            }
        }
        isDragging = false
        super.mouseUp(with: event)
    }
    
    private func performMagneticSnap(for window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        var targetOrigin = frame.origin
        
        let distLeft = abs(frame.minX - visible.minX)
        let distRight = abs(visible.maxX - frame.maxX)
        let distTop = abs(visible.maxY - frame.maxY)
        let distBottom = abs(frame.minY - visible.minY)
        
        let isExpanded = windowController?.state.isExpanded ?? false
        
        if isExpanded {
            // Summary Card: Snap to closest edge if within threshold
            if distLeft < snapThreshold {
                targetOrigin.x = visible.minX + snapMargin
            } else if distRight < snapThreshold {
                targetOrigin.x = visible.maxX - frame.width - snapMargin
            }
            if distTop < snapThreshold {
                targetOrigin.y = visible.maxY - frame.height - snapMargin
            } else if distBottom < snapThreshold {
                targetOrigin.y = visible.minY + snapMargin
            }
        } else {
            // Circular Bubble: Auto snap to the nearest horizontal screen edge (Left or Right)
            if distLeft < distRight {
                targetOrigin.x = visible.minX + snapMargin
                windowController?.state.dockEdge = .left
            } else {
                targetOrigin.x = visible.maxX - frame.width - snapMargin
                windowController?.state.dockEdge = .right
            }
            
            // Keep within vertical bounds with margin
            if distTop < snapThreshold {
                targetOrigin.y = visible.maxY - frame.height - snapMargin
            } else if distBottom < snapThreshold {
                targetOrigin.y = visible.minY + snapMargin
            } else {
                targetOrigin.y = max(visible.minY + snapMargin, min(targetOrigin.y, visible.maxY - frame.height - snapMargin))
            }
        }
        
        // Smooth magnetic spring snap animation
        let targetFrame = NSRect(origin: targetOrigin, size: frame.size)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.windowController?.saveWindowPosition(targetOrigin)
            // Auto-schedule half tuck when idling at edge
            self.windowController?.scheduleTuck()
        })
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        
        if let state = windowController?.state {
            if state.isExpanded {
                let pinItem = NSMenuItem(
                    title: state.isPinned ? L("Unpin Window", "取消置顶") : L("Pin Window", "置顶窗口"),
                    action: #selector(togglePin),
                    keyEquivalent: "p"
                )
                pinItem.target = self
                menu.addItem(pinItem)
                
                let collapseItem = NSMenuItem(
                    title: L("Collapse to Bubble", "收起为悬浮球"),
                    action: #selector(collapseBubble),
                    keyEquivalent: "c"
                )
                collapseItem.target = self
                menu.addItem(collapseItem)
            } else {
                let expandItem = NSMenuItem(
                    title: L("Expand Summary", "展开摘要"),
                    action: #selector(expandSummary),
                    keyEquivalent: "e"
                )
                expandItem.target = self
                menu.addItem(expandItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let consoleItem = NSMenuItem(
            title: L("Open FlowPilot Console", "打开 FlowPilot 控制台"),
            action: #selector(openConsole),
            keyEquivalent: "t"
        )
        consoleItem.target = self
        menu.addItem(consoleItem)
        
        let refreshItem = NSMenuItem(
            title: L("Refresh Telemetry", "刷新遥测数据"),
            action: #selector(refreshData),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(
            title: L("Quit FlowPilot", "退出 FlowPilot"),
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
    public var isInteractingOrDragging: Bool = false
    
    private var hoverDwellTimer: Timer?
    private var collapseTimer: Timer?
    private var tuckTimer: Timer?
    private let bubbleSize = NSSize(width: 76, height: 76)
    private let summarySize = NSSize(width: 384, height: 490)
    
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
        
        // Initial tuck after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.scheduleTuck()
        }
    }
    
    // MARK: - Edge Half-Tuck Support
    public func cancelTuckTimer() {
        tuckTimer?.invalidate()
        tuckTimer = nil
    }
    
    public func scheduleTuck() {
        cancelTuckTimer()
        guard !state.isExpanded, !state.isPinned, !isInteractingOrDragging, state.dockEdge != .none, !state.isDocked else { return }
        tuckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.tuckBubble(animated: true)
        }
    }
    
    public func tuckBubble(animated: Bool = true) {
        guard let window = self.window else { return }
        guard !state.isExpanded, !state.isPinned, !isInteractingOrDragging, state.dockEdge != .none, !state.isDocked else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        
        var targetX = window.frame.origin.x
        if state.dockEdge == .right {
            // Place window flush with right screen edge (pill is right-aligned)
            targetX = visible.maxX - bubbleSize.width
        } else if state.dockEdge == .left {
            // Place window flush with left screen edge (pill is left-aligned)
            targetX = visible.minX
        }
        
        let targetFrame = NSRect(origin: NSPoint(x: targetX, y: window.frame.origin.y), size: bubbleSize)
        state.isDocked = true
        
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }
    
    public func unTuckBubble(animated: Bool = true) {
        cancelTuckTimer()
        guard let window = self.window else { return }
        guard state.isDocked else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        
        var targetX = window.frame.origin.x
        if state.dockEdge == .right {
            targetX = visible.maxX - bubbleSize.width - 8.0
        } else if state.dockEdge == .left {
            targetX = visible.minX + 8.0
        }
        
        let targetFrame = NSRect(origin: NSPoint(x: targetX, y: window.frame.origin.y), size: bubbleSize)
        state.isDocked = false
        
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                window.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.saveWindowPosition(NSPoint(x: targetX, y: window.frame.origin.y))
            })
        } else {
            window.setFrame(targetFrame, display: true)
            saveWindowPosition(NSPoint(x: targetX, y: window.frame.origin.y))
        }
    }
    
    // MARK: - Hover-Dwell 0.4s Detection
    public func cancelDwellTimer() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
    }
    
    public func handleMouseEntered() {
        cancelTuckTimer()
        collapseTimer?.invalidate()
        collapseTimer = nil
        
        if state.isDocked {
            unTuckBubble(animated: true)
        }
        
        guard !state.isExpanded, !isInteractingOrDragging else { return }
        resetDwellTimer()
    }
    
    public func handleMouseMoved() {
        if state.isDocked {
            unTuckBubble(animated: true)
        }
        
        guard !state.isExpanded, !isInteractingOrDragging else { return }
        resetDwellTimer()
    }
    
    private func resetDwellTimer() {
        cancelDwellTimer()
        guard !isInteractingOrDragging else { return }
        // Dwell requirement: cursor stops moving for 0.4 second on the bubble
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, !self.state.isExpanded, !self.isInteractingOrDragging else { return }
            self.state.expand()
        }
    }
    
    public func handleMouseExited() {
        cancelDwellTimer()
        
        // Auto-collapse after grace period if expanded and not pinned
        if state.isExpanded && !state.isPinned && !isInteractingOrDragging {
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self = self, self.state.isExpanded, !self.state.isPinned, !self.isInteractingOrDragging else { return }
                self.state.collapse()
            }
        } else if !state.isExpanded && !state.isDocked && state.dockEdge != .none && !isInteractingOrDragging {
            scheduleTuck()
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
                context.duration = 0.16
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
        DispatchQueue.global(qos: .userInitiated).async {
            let latest = TelemetryQueryEngine.shared.loadLatestRun()
            DispatchQueue.main.async {
                if let run = latest {
                    self.state.update(run: run)
                } else {
                    self.state.latestRun = nil
                    self.state.isTaskRunning = false
                    self.state.loadHistory()
                    self.state.loadStats()
                }
            }
        }
    }
}
