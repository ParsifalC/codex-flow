import Foundation
import Cocoa

public class IPCService {
    public static var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        let dir = URL(fileURLWithPath: codexHome).appendingPathComponent("codex-flow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("overlay.sock").path
    }
    
    // MARK: - Server Implementation
    public class Server {
        public let state: OverlayState
        private var serverSource: DispatchSourceRead?
        private var serverSocket: Int32 = -1
        private let path: String
        
        public init(state: OverlayState, socketPath: String = IPCService.socketPath) {
            self.state = state
            self.path = socketPath
            start()
        }
        
        public func start() {
            unlink(path)
            
            serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverSocket >= 0 else { return }
            
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathMax = MemoryLayout.size(ofValue: addr.sun_path)
            
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                _ = path.withCString { cstr in
                    strncpy(rawPtr, cstr, pathMax - 1)
                }
            }
            
            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(serverSocket, sa, addrLen)
                }
            }
            
            guard bindResult == 0 else {
                close(serverSocket)
                return
            }
            
            listen(serverSocket, 5)
            
            let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .main)
            source.setEventHandler { [weak self] in
                self?.acceptConnection()
            }
            source.setCancelHandler { [weak self] in
                if let fd = self?.serverSocket, fd >= 0 {
                    close(fd)
                }
                if let p = self?.path {
                    unlink(p)
                }
            }
            source.resume()
            self.serverSource = source
        }
        
        private func acceptConnection() {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(serverSocket, sa, &clientAddrLen)
                }
            }
            
            guard clientSocket >= 0 else { return }
            
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                if let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    let response = handleCommand(command)
                    if let resData = response.data(using: .utf8) {
                        _ = resData.withUnsafeBytes { raw in
                            write(clientSocket, raw.baseAddress, resData.count)
                        }
                    }
                }
            }
            close(clientSocket)
        }
        
        private func handleCommand(_ cmd: String) -> String {
            if cmd == "status" {
                return "{\"running\": true, \"isExpanded\": \(state.isExpanded), \"isPinned\": \(state.isPinned)}\n"
            } else if cmd == "toggle" {
                state.toggle()
                return "{\"ok\": true, \"action\": \"toggle\", \"isExpanded\": \(state.isExpanded)}\n"
            } else if cmd == "expand" {
                state.expand()
                return "{\"ok\": true, \"action\": \"expand\"}\n"
            } else if cmd == "collapse" {
                state.collapse()
                return "{\"ok\": true, \"action\": \"collapse\"}\n"
            } else if cmd.hasPrefix("update") {
                let payload = cmd.dropFirst("update".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload.isEmpty {
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
                    let lastUrl = URL(fileURLWithPath: codexHome).appendingPathComponent("codex-flow").appendingPathComponent("telemetry").appendingPathComponent("last.json")
                    if let data = try? Data(contentsOf: lastUrl),
                       let run = try? JSONDecoder().decode(TaskRun.self, from: data) {
                        state.update(run: run)
                        state.expand()
                        return "{\"ok\": true, \"updatedFrom\": \"last.json\"}\n"
                    }
                    state.expand()
                    return "{\"ok\": true, \"action\": \"expanded\"}\n"
                } else {
                    if let fileData = try? Data(contentsOf: URL(fileURLWithPath: payload)),
                       let run = try? JSONDecoder().decode(TaskRun.self, from: fileData) {
                        state.update(run: run)
                        state.expand()
                        return "{\"ok\": true, \"updatedFrom\": \"file\"}\n"
                    } else if let json = payload.data(using: .utf8),
                              let run = try? JSONDecoder().decode(TaskRun.self, from: json) {
                        state.update(run: run)
                        state.expand()
                        return "{\"ok\": true, \"updatedFrom\": \"json\"}\n"
                    }
                }
                return "{\"ok\": false, \"error\": \"invalid payload\"}\n"
            } else if cmd == "quit" || cmd == "stop" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApplication.shared.terminate(nil)
                }
                return "{\"ok\": true, \"action\": \"quitting\"}\n"
            }
            return "{\"ok\": false, \"error\": \"unknown command\"}\n"
        }
        
        public func stop() {
            serverSource?.cancel()
            serverSource = nil
        }
    }
    
    // MARK: - Client Implementation
    public static func sendCommand(_ cmd: String, socketPath: String = IPCService.socketPath) -> (success: Bool, response: String) {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return (false, "Overlay is not running (socket not found).")
        }
        
        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            return (false, "Failed to create client socket.")
        }
        defer { close(clientSocket) }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathMax = MemoryLayout.size(ofValue: addr.sun_path)
        
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = socketPath.withCString { cstr in
                strncpy(rawPtr, cstr, pathMax - 1)
            }
        }
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(clientSocket, sa, addrLen)
            }
        }
        
        guard connectResult == 0 else {
            return (false, "Failed to connect to overlay socket.")
        }
        
        guard let data = cmd.data(using: .utf8) else {
            return (false, "Encoding error.")
        }
        
        _ = data.withUnsafeBytes { raw in
            write(clientSocket, raw.baseAddress, data.count)
        }
        
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)
        if bytesRead > 0 {
            let response = String(data: Data(buffer[0..<bytesRead]), encoding: .utf8) ?? ""
            return (true, response.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return (true, "OK")
    }
}
