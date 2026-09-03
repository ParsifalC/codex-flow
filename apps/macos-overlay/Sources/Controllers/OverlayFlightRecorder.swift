import Cocoa

/// Lightweight geometry/event recorder for diagnosing hard-to-reproduce overlay
/// positioning failures on real multi-display systems. It intentionally records
/// only window/screen/pointer geometry and presentation state, never task text.
final class OverlayFlightRecorder {
    static let shared = OverlayFlightRecorder()

    private let queue = DispatchQueue(label: "codex-flow.overlay-flight-recorder")
    private let logURL: URL
    private let maxBytes: UInt64 = 1_000_000

    private init() {
        let environment = ProcessInfo.processInfo.environment
        let codexHome: URL
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }

        let logDirectory = codexHome
            .appendingPathComponent("codex-flow", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        logURL = logDirectory.appendingPathComponent("overlay-flight.log")
    }

    func record(
        _ event: String,
        windowFrame: NSRect?,
        targetFrame: NSRect? = nil,
        visibleFrame: NSRect? = nil,
        pointer: NSPoint? = nil,
        expanded: Bool,
        docked: Bool,
        geometry: String
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = [
            timestamp,
            "event=\(event)",
            "expanded=\(expanded)",
            "docked=\(docked)",
            "geometry=\(geometry)",
            "window=\(describe(windowFrame))",
            "target=\(describe(targetFrame))",
            "screen=\(describe(visibleFrame))",
            "pointer=\(describe(pointer))"
        ].joined(separator: " ") + "\n"

        queue.async { [logURL, maxBytes] in
            let manager = FileManager.default
            if let attrs = try? manager.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? NSNumber,
               size.uint64Value >= maxBytes {
                try? manager.removeItem(at: logURL)
            }

            if !manager.fileExists(atPath: logURL.path) {
                manager.createFile(atPath: logURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Diagnostics must never affect overlay behavior.
            }
        }
    }

    private func describe(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "{x=%.1f,y=%.1f,w=%.1f,h=%.1f}",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private func describe(_ point: NSPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "{x=%.1f,y=%.1f}", point.x, point.y)
    }
}
