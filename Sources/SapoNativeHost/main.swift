import Foundation
import Dispatch

/// Native messaging host for Chrome → Sapo tab capture.
/// Chrome spawns this process via `connectNative()`, keeps it running
/// until the port is destroyed. The first argument is the calling
/// extension's origin.
///
/// Protocol: reads 4-byte native-endian (little-endian on macOS) JSON
/// message length, then UTF-8 JSON body from stdin. Forwards audio
/// data over TCP to Sapo's TabCaptureSession on localhost:5678.

struct NativeMessage: Codable {
    let type: String   // "audio", "silence", "error", "tablist"
    let tabId: String
    let data: String?  // base64-encoded Float32 PCM (for "audio" type)
    let message: String?  // for "error" type
    let tabs: [HostTab]?  // for "tablist" type
}

struct HostTab: Codable {
    let id: Int
    let title: String
    let audible: Bool
}

struct TabAudioHeader: Codable {
    let tabId: String
    let sampleRate: Int
    let frameCount: Int
}

struct BrowserTabList: Codable {
    let tabs: [HostTab]
}

@main
struct NativeHost {
    static func main() {
        let stdinFile = FileHandle.standardInput
        let stdoutFile = FileHandle.standardOutput
        let stderrFile = FileHandle.standardError
        
        func log(_ message: String) {
            // Native messaging hosts MUST NOT write anything to stdout except
            // length-prefixed JSON — Chrome kills the host otherwise. Debug goes to stderr.
            stderrFile.write(Data((message + "\n").utf8))
        }
        
        // First argument is the calling extension's origin
        let origin = CommandLine.arguments.dropFirst().first ?? ""
        log("Native host started, origin: \(origin)")
        
        // TCP connections to Sapo: audio (5678, persistent during capture)
        // and the registry (5679, short-lived per tab-list push).
        var audioConnection: TCPConnection?
        var registryConnection: TCPConnection?
        
        while true {
            // Read exactly 4 bytes (pipes deliver short reads — loop until full)
            guard let lengthData = readExact(stdinFile, count: 4) else {
                // EOF or error — Chrome disconnected
                break
            }
            
            // Convert native-endian (little-endian on macOS) to UInt32
            let lengthBytes = lengthData.withUnsafeBytes { ptr in
                ptr.load(as: UInt32.self)
            }
            let messageLength = Int(lengthBytes)
            guard messageLength > 0, messageLength <= 64 * 1024 * 1024 else { continue }
            
            // Read exactly messageLength bytes of JSON
            guard let jsonBody = readExact(stdinFile, count: messageLength) else {
                break
            }
            
            // Decode message
            guard let message = try? JSONDecoder().decode(NativeMessage.self, from: jsonBody) else {
                continue
            }
            
            switch message.type {
            case "audio":
                // Connect TCP on first audio message if not already connected
                if audioConnection == nil {
                    do {
                        audioConnection = try TCPConnection(host: "127.0.0.1", port: 5678)
                    } catch {
                        log("Failed to connect to Sapo: \(error)")
                        sendNativeMessage(stdout: stdoutFile, type: "error", tabId: message.tabId, message: "TCP connection failed")
                        continue
                    }
                }
                
                // Decode base64 → raw Float32 bytes
                guard let encodedData = Data(base64Encoded: message.data?.data(using: .utf8) ?? Data()) else {
                    sendNativeMessage(stdout: stdoutFile, type: "error", tabId: message.tabId, message: "Invalid base64")
                    continue
                }
                
                // Send TCP header + raw PCM
                guard audioConnection?.isConnected == true else {
                    sendNativeMessage(stdout: stdoutFile, type: "error", tabId: message.tabId, message: "TCP not connected")
                    continue
                }
                
                let header = TabAudioHeader(tabId: message.tabId, sampleRate: 48000, frameCount: encodedData.count / 4)
                var headerJSON = (try? JSONEncoder().encode(header)) ?? Data()
                headerJSON.append(0x0A) // newline terminator — Sapo's TCP server reads header until \n
                audioConnection?.write(headerJSON)
                audioConnection?.write(encodedData)
                
            case "tablist":
                // Forward the tab list to Sapo's registry (5679) as one
                // NDJSON line. Short-lived connection per push: connect,
                // write, disconnect. Sapo keeps accepting clients.
                guard let tabs = message.tabs else { continue }
                let payload = BrowserTabList(tabs: tabs)
                guard var line = try? JSONEncoder().encode(payload) else { continue }
                line.append(0x0A)
                if registryConnection?.isConnected != true {
                    registryConnection = try? TCPConnection(host: "127.0.0.1", port: 5679)
                }
                if registryConnection?.isConnected == true {
                    registryConnection?.write(line)
                    registryConnection?.disconnect()
                    registryConnection = nil
                } else {
                    log("Registry push skipped — Sapo not listening on 5679")
                }
                
            case "silence":
                // No-op — silence doesn't need TCP relay
                break
                
            case "error":
                log("Chrome error: \(message.message ?? "unknown")")
                
            default:
                break
            }
        }
        
        audioConnection?.disconnect()
        registryConnection?.disconnect()
    }
    
    /// Read exactly `count` bytes from a FileHandle, looping across short
    /// pipe reads. Returns nil on EOF before any byte; empty Data if EOF hit
    /// mid-message (caller treats both as disconnect).
    private static func readExact(_ file: FileHandle, count: Int) -> Data? {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try? file.read(upToCount: count - data.count), !chunk.isEmpty else {
                return data.isEmpty ? nil : Data()
            }
            data.append(chunk)
        }
        return data
    }
    
    private static func sendNativeMessage(stdout: FileHandle, type: String, tabId: String, message: String?) {
        let msg = NativeMessage(type: type, tabId: tabId, data: nil, message: message, tabs: nil)
        let data = try? JSONEncoder().encode(msg)
        var length = UInt32(data?.count ?? 0).nativeToLittleEndian()
        stdout.write(Data(bytes: &length, count: 4))
        if let data { stdout.write(data) }
    }
}

extension UInt32 {
    func nativeToLittleEndian() -> UInt32 {
        #if arch(arm64) || arch(x86_64)
        return self.littleEndian
        #else
        return self
        #endif
    }
}

/// Minimal TCP client for localhost:5678
final class TCPConnection {
    private var socketFD: CInt = -1
    var isConnected: Bool { socketFD >= 0 }
    
    init(host: String, port: Int) throws {
        // Create IPv4 TCP socket
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: "TCPConnection", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        
        // Connect
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        
        var addrBytes = sockaddr()
        memcpy(&addrBytes, &addr, MemoryLayout<sockaddr_in>.size)
        
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        let result = connect(socketFD, &addrBytes, socklen_t(MemoryLayout<sockaddr_in>.size))
        guard result == 0 else {
            disconnect()
            throw NSError(domain: "TCPConnection", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect() failed"])
        }
    }
    
    func write(_ data: Data) {
        guard socketFD >= 0 else { return }
        _ = data.withUnsafeBytes { ptr in
            send(socketFD, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), data.count, 0)
        }
    }
    
    func disconnect() {
        if socketFD >= 0 {
            _ = close(socketFD)
            socketFD = -1
        }
    }
    
    deinit { disconnect() }
}
