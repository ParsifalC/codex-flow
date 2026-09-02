import Foundation

public class TelemetryWatcher {
    public let state: OverlayState
    private var telemetryURL: URL
    private var dirURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var lastModifiedTime: Date = .distantPast
    
    public init(state: OverlayState, telemetryPath: String? = nil) {
        self.state = state
        if let path = telemetryPath {
            self.telemetryURL = URL(fileURLWithPath: path)
            self.dirURL = self.telemetryURL.deletingLastPathComponent()
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
            self.dirURL = URL(fileURLWithPath: codexHome)
                .appendingPathComponent("codex-flow")
                .appendingPathComponent("telemetry")
            self.telemetryURL = self.dirURL.appendingPathComponent("last.json")
        }
        
        // Initial load
        loadLatestData()
        startWatching()
    }
    
    deinit {
        stopWatching()
    }
    
    /// Starts passive, kernel-driven file & directory monitoring (0% idle CPU, zero battery drain)
    public func startWatching() {
        stopWatching()
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        
        // 1. Watch directory for atomic writes / renames / replacements
        let dirFD = open(dirURL.path, O_EVTONLY)
        if dirFD >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFD,
                eventMask: [.write, .extend, .attrib, .link],
                queue: DispatchQueue.global(qos: .utility)
            )
            
            source.setEventHandler { [weak self] in
                self?.handleFileOrDirChanged()
            }
            
            source.setCancelHandler {
                close(dirFD)
            }
            
            source.resume()
            self.dirSource = source
        }
        
        // 2. Watch specific last.json file if it exists
        if FileManager.default.fileExists(atPath: telemetryURL.path) {
            let fileFD = open(telemetryURL.path, O_EVTONLY)
            if fileFD >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fileFD,
                    eventMask: [.write, .extend, .attrib, .rename, .delete],
                    queue: DispatchQueue.global(qos: .utility)
                )
                
                source.setEventHandler { [weak self, weak source] in
                    guard let self = self else { return }
                    let flags = source?.data ?? []
                    if flags.contains(.rename) || flags.contains(.delete) {
                        self.fileSource?.cancel()
                        self.fileSource = nil
                    }
                    self.handleFileOrDirChanged()
                }
                
                source.setCancelHandler {
                    close(fileFD)
                }
                
                source.resume()
                self.fileSource = source
            }
        }
    }
    
    public func stopWatching() {
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil
    }
    
    private func handleFileOrDirChanged() {
        // Debounce slightly (50ms) to ensure file write buffer flushed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.checkAndReloadIfModified()
            // Re-attach file watcher if file was recreated/renamed
            if self.fileSource == nil && FileManager.default.fileExists(atPath: self.telemetryURL.path) {
                self.startWatching()
            }
        }
    }
    
    public func checkAndReloadIfModified() {
        guard FileManager.default.fileExists(atPath: telemetryURL.path) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: telemetryURL.path)
            if let modDate = attrs[.modificationDate] as? Date, modDate > lastModifiedTime {
                lastModifiedTime = modDate
                loadLatestData()
            }
        } catch {
            // Ignore temporary read attribute errors
        }
    }
    
    public func loadLatestData() {
        guard FileManager.default.fileExists(atPath: telemetryURL.path) else { return }
        do {
            let data = try Data(contentsOf: telemetryURL)
            let decoder = JSONDecoder()
            var run = try decoder.decode(TaskRun.self, from: data)
            TelemetryQueryEngine.shared.enrichRunIfNeeded(&run)
            state.update(run: run)
        } catch {
            // If decode fails, retain existing state
        }
    }
}
