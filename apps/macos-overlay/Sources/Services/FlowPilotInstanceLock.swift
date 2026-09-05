import Foundation
import Darwin

/// Process-lifetime singleton lock for the native FlowPilot overlay.
///
/// The lock file is deliberately never removed.  `flock` tracks ownership by
/// open file description, so a process crash releases the lock while keeping a
/// stable path for future processes to open.  The descriptor is marked
/// close-on-exec so helper processes cannot accidentally keep the overlay
/// alive after the app exits.
public final class FlowPilotInstanceLock {
    public static let launchAgentEnvironmentKey = "CODEX_FLOW_LAUNCHD_START"
    public static let manualHandoffTimeout: TimeInterval = 5.0

    public static var lockPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? home.appendingPathComponent(".codex").path
        let directory = URL(fileURLWithPath: codexHome).appendingPathComponent("codex-flow")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("overlay.lock").path
    }

    public static var isLaunchAgentStart: Bool {
        guard let raw = ProcessInfo.processInfo.environment[launchAgentEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    public enum LockError: Error, LocalizedError {
        case openFailed(path: String, errno: Int32)
        case acquisitionFailed(path: String, errno: Int32)
        case timedOut(path: String, timeout: TimeInterval)
        case closed

        public var errorDescription: String? {
            switch self {
            case let .openFailed(path, errorNumber):
                return "Could not open FlowPilot instance lock at \(path): \(Self.message(for: errorNumber))"
            case let .acquisitionFailed(path, errorNumber):
                return "Could not acquire FlowPilot instance lock at \(path): \(Self.message(for: errorNumber))"
            case let .timedOut(path, timeout):
                return "Timed out after \(String(format: "%.1f", timeout))s waiting for FlowPilot instance lock at \(path)."
            case .closed:
                return "FlowPilot instance lock is closed."
            }
        }

        private static func message(for errorNumber: Int32) -> String {
            guard let message = strerror(errorNumber) else {
                return "errno \(errorNumber)"
            }
            return String(cString: message)
        }
    }

    private let path: String
    private var fileDescriptor: Int32
    private var ownsLock = false

    public init(path: String = FlowPilotInstanceLock.lockPath) throws {
        self.path = path

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let mode = mode_t(0o600)
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            throw LockError.openFailed(path: path, errno: errno)
        }

        self.fileDescriptor = descriptor
        // `open(..., 0600)` only applies when the file is created.  Tighten an
        // existing lock left by an older build as well, without replacing its
        // inode or disturbing an active flock owner.
        if fchmod(descriptor, mode) != 0 {
            let errorNumber = errno
            close(descriptor)
            throw LockError.openFailed(path: path, errno: errorNumber)
        }
    }

    /// Acquire the exclusive lock, retrying transient contention until the
    /// monotonic timeout expires.  A zero timeout performs one non-blocking
    /// attempt, which is used to decide whether a manual handoff is needed.
    public func acquire(timeout: TimeInterval) throws {
        guard fileDescriptor >= 0 else { throw LockError.closed }

        if ownsLock { return }
        let deadline = Self.monotonicDeadline(after: timeout)

        while true {
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                ownsLock = true
                return
            }

            let errorNumber = errno
            guard errorNumber == EINTR || errorNumber == EWOULDBLOCK || errorNumber == EAGAIN else {
                throw LockError.acquisitionFailed(path: path, errno: errorNumber)
            }

            let current = Self.monotonicNow()
            if current >= deadline {
                throw LockError.timedOut(path: path, timeout: max(0, timeout))
            }

            // A short bounded sleep avoids a busy loop while keeping handoff
            // responsive.  If usleep is interrupted, the outer loop retries
            // and re-checks the same monotonic deadline.
            let remaining = deadline - current
            let micros = min(UInt64(10_000), max(UInt64(1), remaining / 1_000))
            _ = usleep(UInt32(min(micros, UInt64(UInt32.max))))
        }
    }

    /// Release ownership and close the descriptor.  The lock file itself is
    /// intentionally retained for the next process to open.
    public func release() {
        guard fileDescriptor >= 0 else { return }
        if ownsLock {
            _ = flock(fileDescriptor, LOCK_UN)
            ownsLock = false
        }
        close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }

    private static func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func monotonicDeadline(after timeout: TimeInterval) -> UInt64 {
        let now = monotonicNow()
        guard timeout.isFinite, timeout > 0 else {
            return timeout.isFinite ? now : UInt64.max
        }

        let requested = timeout * 1_000_000_000
        let delta = requested >= Double(UInt64.max)
            ? UInt64.max
            : UInt64(max(1, requested.rounded(.up)))
        return UInt64.max - now < delta ? UInt64.max : now + delta
    }
}
