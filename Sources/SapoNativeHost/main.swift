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
    let type: String   // "audio", "silence", "error"
    let tabId: String
    let data: String?  // base64-encoded Float32 PCM (for "audio" type)
    let message: String?  // for "error" type
}

struct TCPOutputHeader: Codable {
    let tabId: String
    let sampleRate: Int
    let frameCount: Int
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
        
        // TCP connection to Sapo (lazy — connect on first audio message)
        var tcpConnection: TCPConnection?
        
        while true {
            // Read 4-byte length prefix
            guard let lengthData = try? stdinFile.read(upToCount: 4) else {
                // EOF or error — Chrome disconnected
                break
            }
            guard lengthData.count == 4 else { continue }
            
            // Convert native-endian (little-endian on macOS) to UInt32
            let lengthBytes = lengthData.withUnsafeBytes { ptr in
                ptr.load(as: UInt32.self)
            }
            let messageLength = Int(lengthBytes)
            
            // Read JSON body
            guard let jsonBody = try? stdinFile.read(upToCount: messageLength) else {
                break
            }
            
            // Decode message
            guard let message = try? JSONDecoder().decode(NativeMessage.self, from: jsonBody) else {
                continue
            }
            
            switch message.type {
            case "audio":
                // Connect TCP on first audio message if not already connected
                if tcpConnection == nil {
                    do {
                        tcpConnection = try TCPConnection(host: "127.0.0.1", port: 5678)
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
                guard tcpConnection?.isConnected == true else {
                    sendNativeMessage(stdout: stdoutFile, type: "error", tabId: message.tabId, message: "TCP not connected")
                    continue
                }
                
                let header = TCPOutputHeader(tabId: message.tabId, sampleRate: 48000, frameCount: encodedData.count / 4)
                var headerJSON = (try? JSONEncoder().encode(header)) ?? Data()
                headerJSON.append(0x0A) // newline terminator — Sapo's TCP server reads header until \n
                tcpConnection?.write(headerJSON)
                tcpConnection?.write(encodedData)
                
            case "silence":
                // No-op — silence doesn't need TCP relay
                break
                
            case "error":
                log("Chrome error: \(message.message ?? "unknown")")
                
            default:
                break
            }
        }
        
        tcpConnection?.disconnect()
    }
    
    private static func sendNativeMessage(stdout: FileHandle, type: String, tabId: String, message: String?) {
        let msg = NativeMessage(type: type, tabId: tabId, data: nil, message: message)
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
