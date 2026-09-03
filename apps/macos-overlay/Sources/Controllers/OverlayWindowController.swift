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
    @Published public var isPrivacyMode: Bool = false

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
    @Published public var recentChats: [ChatSession] = []
    @Published public var allProjectsList: [String] = []

    public weak var windowController: OverlayWindowController?

    // All mutations to these request generations are marshalled onto the main
    // queue. They prevent slower, older queries from overwriting a newer filter
    // or time-range selection after the background work completes.
    private var historyLoadGeneration = 0
    private var statsLoadGeneration = 0

    public init() {
        if let latest = TelemetryQueryEngine.shared.loadLatestRun() {
            self.latestRun = latest
            self.isTaskRunning = latest.isRunning
        }
        self.loadMenuData()
    }

    public func loadMenuData() {
        DispatchQueue.global(qos: .userInitiated).async {
            let chats = TelemetryQueryEngine.shared.fetchChatHistory(limit: 15)
            let projs = TelemetryQueryEngine.shared.allProjects()
            DispatchQueue.main.async {
                self.recentChats = chats
                self.allProjectsList = projs
            }
        }
    }

    public func expand() {
        guard !isExpanded else { return }
        self.loadMenuData()
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
            self.isDocked = false
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
        var r = run
        DispatchQueue.main.async {
            self.inspectedRun = r
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
        }
        if r.trajectory == nil || r.skillsUsed == nil || r.toolsUsed == nil || r.logs == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                TelemetryQueryEngine.shared.enrichRunIfNeeded(&r)
                DispatchQueue.main.async {
                    if self.inspectedRun?.id == r.id {
                        self.inspectedRun = r
                    }
                }
            }
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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.loadHistory() }
            return
        }

        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        let proj = selectedProject
        let today = isTodayOnly
        let search = searchQuery

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
                guard generation == self.historyLoadGeneration else { return }
                self.historyChats = chats
                self.historyRuns = runs
                if self.expandedChatIds.isEmpty, let first = chats.first {
                    self.expandedChatIds.insert(first.sessionId)
                }
            }
        }
    }

    public func loadStats() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.loadStats() }
            return
        }

        statsLoadGeneration += 1
        let generation = statsLoadGeneration
        let days = statsDays
        let project = selectedProject

        DispatchQueue.global(qos: .userInitiated).async {
            let stats = TelemetryQueryEngine.shared.computeStats(
                days: days,
                project: project
            )
            DispatchQueue.main.async {
                guard generation == self.statsLoadGeneration else { return }
                self.statsData = stats
            }
        }
    }

    public func update(run: TaskRun) {
        DispatchQueue.main.async {
            self.latestRun = run
            self.isTaskRunning = run.isRunning
            if self.activeTab == .history {
                self.loadHistory()
            } else if self.activeTab == .analytics {
                self.loadStats()
            }
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
        let align: Alignment = (state.dockEdge == .left) ? .topLeading : .topTrailing
        let anchorPoint: UnitPoint = (state.dockEdge == .left) ? .topLeading : .topTrailing

        ZStack(alignment: align) {
            if state.isExpanded {
                SummaryView(state: state)
                    .frame(width: 384)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: anchorPoint)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: anchorPoint))
                        )
                    )
            } else {
                BubbleView(state: state)
                    .frame(width: 76, height: 76)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: anchorPoint)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: anchorPoint))
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
        .background(Color.clear)
        .preferredColorScheme(.dark)
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
    private var initialMouseScreenLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero
    private var isDragging: Bool = false
    private let snapMargin: CGFloat = 8.0
    private let snapThreshold: CGFloat = 36.0

    override func mouseDown(with event: NSEvent) {
        if let window = self.window {
            initialMouseScreenLocation = NSEvent.mouseLocation
            initialWindowOrigin = window.frame.origin
        }
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
        let currentMouseScreen = NSEvent.mouseLocation
        let deltaX = currentMouseScreen.x - initialMouseScreenLocation.x
        let deltaY = currentMouseScreen.y - initialMouseScreenLocation.y
        let dragThreshold: CGFloat = (windowController?.state.isExpanded ?? false) ? 8.0 : 4.0
        if isDragging || abs(deltaX) > dragThreshold || abs(deltaY) > dragThreshold {
            isDragging = true
            windowController?.cancelDwellTimer()
            windowController?.isInteractingOrDragging = true

            var newOrigin = NSPoint(
                x: initialWindowOrigin.x + deltaX,
                y: initialWindowOrigin.y + deltaY
            )

            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                newOrigin.x = max(visible.minX, min(newOrigin.x, visible.maxX - window.frame.width))
                newOrigin.y = max(visible.minY + 24, min(newOrigin.y, visible.maxY - window.frame.height - 24))
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.windowController?.isInteractingOrDragging = false
            }
        } else {
            windowController?.isInteractingOrDragging = false
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
            // Scheme A: Dual-sided smart magnetic snap (iOS AssistiveTouch behavior)
            let toLeft = frame.midX < visible.midX
            if toLeft {
                targetOrigin.x = visible.minX
                windowController?.state.dockEdge = .left
            } else {
                targetOrigin.x = visible.maxX - frame.width
                windowController?.state.dockEdge = .right
            }
            windowController?.state.isDocked = false

            if distTop < snapThreshold {
                targetOrigin.y = visible.maxY - frame.height - 24
            } else if distBottom < snapThreshold {
                targetOrigin.y = visible.minY + 24
            } else {
                targetOrigin.y = max(visible.minY + 24, min(targetOrigin.y, visible.maxY - frame.height - 24))
            }
        }

        let targetFrame = NSRect(origin: targetOrigin, size: frame.size)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.windowController?.saveWindowPosition(targetOrigin)
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
    private let edgeTuckIdleInterval: TimeInterval = 30.0
    // Programmatic window moves can synthesize tracking-area enter/exit events.
    // Remember the pointer position before a collapse/tuck and require genuine
    // pointer movement before hover behavior is re-armed. This breaks the
    // feedback loop where the window moves under a stationary cursor, receives
    // mouseEntered, reverses the move, then receives mouseExited and tucks again.
    private var hoverRearmPointerLocation: NSPoint?
    private let hoverRearmDistance: CGFloat = 2.0
    private let bubbleSize = NSSize(width: 76, height: 76)
    private let summarySize = NSSize(width: 384, height: 490)

    public init(state: OverlayState) {
        self.state = state
        super.init()
        state.windowController = self
        setupWindow()
    }

    private func setupWindow() {
        let restored = loadSavedPosition() ?? defaultPosition(for: bubbleSize)
        let initialRect = normalizedCollapsedFrame(restored)

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
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.delegate = self

        let rootView = OverlayRootView(state: state)
        let hostingView = TrackingHostingView(rootView: rootView)
        hostingView.windowController = self
        window.contentView = hostingView

        window.orderFront(nil)

        // Automatically collapse expanded panel on outside clicks
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            if self.state.isExpanded && !self.state.isPinned && !self.isInteractingOrDragging {
                self.state.collapse()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + edgeTuckIdleInterval) { [weak self] in
            self?.scheduleTuck()
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        if state.isExpanded && !state.isPinned && !isInteractingOrDragging {
            state.collapse()
        }
    }

    // MARK: - Edge Half-Tuck Support
    public func cancelTuckTimer() {
        tuckTimer?.invalidate()
        tuckTimer = nil
    }

    public func scheduleTuck() {
        cancelTuckTimer()
        guard !state.isExpanded, !state.isPinned, !isInteractingOrDragging, !state.isDocked else { return }
        tuckTimer = Timer.scheduledTimer(withTimeInterval: edgeTuckIdleInterval, repeats: false) { [weak self] _ in
            self?.tuckBubble(animated: true)
        }
    }

    private func suppressHoverUntilPointerMoves() {
        hoverRearmPointerLocation = NSEvent.mouseLocation
        cancelDwellTimer()
    }

    private func pointerMovementRearmedHover() -> Bool {
        guard let anchor = hoverRearmPointerLocation else { return true }
        let current = NSEvent.mouseLocation
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let minimumDistanceSquared = hoverRearmDistance * hoverRearmDistance
        guard dx * dx + dy * dy >= minimumDistanceSquared else { return false }
        hoverRearmPointerLocation = nil
        return true
    }

    public func tuckBubble(animated: Bool = true) {
        guard let window = self.window else { return }
        guard !state.isExpanded, !state.isPinned, !isInteractingOrDragging, !state.isDocked else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let isLeft = (state.dockEdge == .left)
        let targetX = isLeft ? visible.minX : (visible.maxX - bubbleSize.width)
        let targetY = max(visible.minY + 24, min(window.frame.origin.y, visible.maxY - bubbleSize.height - 24))

        let targetFrame = NSRect(origin: NSPoint(x: targetX, y: targetY), size: bubbleSize)
        suppressHoverUntilPointerMoves()
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
        guard self.window != nil else { return }
        guard state.isDocked else { return }
        state.isDocked = false
    }

    // MARK: - Hover-Dwell 0.4s Detection
    public func cancelDwellTimer() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
    }

    public func handleMouseEntered() {
        // A tracking-area enter caused only by our own frame animation is not
        // user intent. Ignoring it is what makes idle collapse/tuck idempotent.
        guard pointerMovementRearmedHover() else { return }

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
        guard pointerMovementRearmedHover() else { return }

        if state.isDocked {
            unTuckBubble(animated: true)
        }

        guard !state.isExpanded, !isInteractingOrDragging else { return }
        resetDwellTimer()
    }

    private func resetDwellTimer() {
        cancelDwellTimer()
        guard !isInteractingOrDragging else { return }
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, !self.state.isExpanded, !self.isInteractingOrDragging else { return }
            self.state.expand()
        }
    }

    public func handleMouseExited() {
        cancelDwellTimer()

        if state.isExpanded && !state.isPinned && !isInteractingOrDragging {
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self = self, self.state.isExpanded, !self.state.isPinned, !self.isInteractingOrDragging else { return }
                self.state.collapse()
            }
        } else if !state.isExpanded && !state.isDocked && !isInteractingOrDragging {
            scheduleTuck()
        }
    }

    // MARK: - Frame Resizing & Animation
    public func updateWindowFrame(animated: Bool = true) {
        guard let window = self.window else { return }
        let targetSize = state.isExpanded ? summarySize : bubbleSize
        let currentFrame = window.frame

        var newOrigin: NSPoint
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let isLeft = (state.dockEdge == .left)
            let x: CGFloat = isLeft ? visible.minX : (visible.maxX - targetSize.width)
            let y = max(visible.minY + 24, min(currentFrame.maxY - targetSize.height, visible.maxY - targetSize.height - 24))
            newOrigin = NSPoint(x: x, y: y)
        } else {
            newOrigin = NSPoint(
                x: currentFrame.maxX - targetSize.width,
                y: currentFrame.maxY - targetSize.height
            )
        }

        let newFrame = NSRect(origin: newOrigin, size: targetSize)

        if !state.isExpanded {
            // Resizing the summary into the collapsed bubble can move the new
            // tracking area under a stationary cursor. Do not let that synthetic
            // enter immediately expand or untuck the bubble again.
            suppressHoverUntilPointerMoves()
        }

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

    private func normalizedCollapsedFrame(_ frame: NSRect) -> NSRect {
        let visible = screen(forSavedFrame: frame)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let isLeft = frame.midX < visible.midX
        state.dockEdge = isLeft ? .left : .right
        let x = isLeft ? visible.minX : (visible.maxX - bubbleSize.width)
        let y = max(visible.minY + 24, min(frame.origin.y, visible.maxY - bubbleSize.height - 24))
        return NSRect(origin: NSPoint(x: x, y: y), size: bubbleSize)
    }

    private func screen(forSavedFrame frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main }

        // Persisted coordinates are in global screen space. Prefer the screen
        // containing the saved bubble's center, then its origin for partially
        // off-screen frames (for example after a display was disconnected).
        let anchors = [
            NSPoint(x: frame.midX, y: frame.midY),
            frame.origin
        ]
        for anchor in anchors {
            if let screen = screens.first(where: { $0.visibleFrame.contains(anchor) }) {
                return screen
            }
        }

        // If the saved frame is no longer on any display, keep it on the
        // nearest visible frame rather than unexpectedly moving it to the
        // primary display. NSScreen.main remains the final deterministic
        // fallback when there is no useful geometry.
        let center = NSPoint(x: frame.midX, y: frame.midY)
        func distanceSquared(to rect: NSRect) -> CGFloat {
            let x = max(rect.minX, min(center.x, rect.maxX))
            let y = max(rect.minY, min(center.y, rect.maxY))
            let dx = center.x - x
            let dy = center.y - y
            return dx * dx + dy * dy
        }
        return screens.min { distanceSquared(to: $0.visibleFrame) < distanceSquared(to: $1.visibleFrame) }
            ?? NSScreen.main
    }

    private func defaultPosition(for size: NSSize) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.maxX - size.width
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
