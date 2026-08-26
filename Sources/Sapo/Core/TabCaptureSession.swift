import Foundation
import AudioToolbox

/// Protocol for both CaptureChain and TabCaptureSession.
/// Provides onLevel/onEnded callbacks, client format, and lifecycle methods.
protocol CaptureUnit: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onEnded: ((String) -> Void)? { get set }
    var clientFormat: AudioStreamBasicDescription { get }
    func start() throws
    func stop(reason: String)
}

/// Receives tab audio over TCP, writes directly to stem file.
/// No CaptureChain — tab capture has no Core Audio device.
/// Instead, we write directly to StemWriter and track levels separately.
final class TabCaptureSession: CaptureUnit {
    let stemWriter: StemWriter
    private let tcpServer: TCPServer
    private let tabID: String
    private var onLevelCallback: ((Float) -> Void)?
    private var onEndedCallback: ((String) -> Void)?
    private var lastLevelAt: Double = 0
    private var totalFrames: UInt32 = 0
    private var streamFormat: AudioStreamBasicDescription
    
    struct TCPOutputHeader: Codable {
        let tabId: String
        let sampleRate: Int
        let frameCount: Int
    }
    
    /// Create a tab capture session. Does not start listening — call
    /// `start()` to begin accepting TCP connections.
    static func make(stemURL: URL, format: StemFormat, tabID: String) throws -> TabCaptureSession {
        // Fixed format: 32-bit float PCM, 48kHz, mono
        let clientFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        let writer = try StemWriter(url: stemURL, clientFormat: clientFormat, format: format)
        return TabCaptureSession(stemWriter: writer, tabID: tabID, streamFormat: clientFormat)
    }
    
    init(stemWriter: StemWriter, tabID: String, streamFormat: AudioStreamBasicDescription, port: Int = 5678) {
        self.stemWriter = stemWriter
        self.tabID = tabID
        self.streamFormat = streamFormat
        self.tcpServer = TCPServer(port: port)
    }
    
    var onLevel: ((Float) -> Void)? {
        get { onLevelCallback }
        set { onLevelCallback = newValue }
    }
    
    var onEnded: ((String) -> Void)? {
        get { onEndedCallback }
        set { onEndedCallback = newValue }
    }
    
    /// Exposed for RecorderEngine to access the client format.
    var clientFormat: AudioStreamBasicDescription { streamFormat }
    
    func start() throws {
        // Verify callbacks are set before starting TCP server
        guard onLevel != nil, onEnded != nil else {
            throw NSError(domain: "TabCaptureSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "callbacks not set"])
        }
        
        try tcpServer.start { [weak self] headerData, pcmData in
            guard let self else { return }
            
            // Parse JSON header (validate format, value unused)
            _ = try? JSONDecoder().decode(TCPOutputHeader.self, from: headerData)
            
            // Write PCM data to stem
            do {
                let frameCount = UInt32(pcmData.count / 4) // Float32 = 4 bytes
                try self.writePCM(pcmData, frameCount: frameCount)
                self.totalFrames += frameCount
                
                // Update level meter (RMS)
                self.updateLevel(from: pcmData)
            } catch {
                print("Stem write error: \(error)")
                self.stop(reason: "deviceLost")
            }
        }
        
        // Accept connections
        tcpServer.acceptConnection()
    }
    
    func stop(reason: String) {
        tcpServer.stop()
        stemWriter.close()
        DispatchQueue.main.async { [weak self] in
            self?.onEndedCallback?(reason)
        }
    }
    
    private func updateLevel(from pcmData: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelAt > 0.1 else { return } // ~10 Hz
        lastLevelAt = now
        
        // Compute RMS from Float32 samples
        guard pcmData.count >= 4 else { return }
        let samples = pcmData.withUnsafeBytes { ptr in
            ptr.bindMemory(to: Float.self).baseAddress!
        }
        let sampleCount = pcmData.count / 4
        var sum: Float = 0
        for i in 0..<sampleCount {
            let v = samples[i]
            sum += v * v
        }
        let rms = sampleCount > 0 ? sqrt(sum / Float(sampleCount)) : 0
        let level = min(rms * 4, 1) // gain for visibility
        
        DispatchQueue.main.async { [weak self] in
            self?.onLevelCallback?(level)
        }
    }
    
    /// Write raw Float32 mono PCM to the stem. Constructs the AudioBufferList
    /// and performs the write within one scope — a pointer to a stack-local
    /// buffer list must never outlive this call (dangling-pointer segfault).
    func writePCM(_ data: Data, frameCount: UInt32) throws {
        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: 1,
                                                        mDataByteSize: UInt32(data.count),
                                                        mData: nil))
        try data.withUnsafeBytes { raw in
            abl.mBuffers.mData = UnsafeMutableRawPointer(mutating: raw.baseAddress)
            // &abl is valid for the duration of this synchronous write call.
            try stemWriter.write(&abl, frameCount: frameCount)
        }
    }
}

/// Minimal TCP server for localhost:5678
final class TCPServer {
    private var listenFD: CInt = -1
    private var clientFD: CInt = -1
    private let port: Int
    private var connectionHandler: ((Data, Data) -> Void)?
    
    init(port: Int) {
        self.port = port
    }
    
    func start(onConnection: @escaping ((Data, Data) -> Void)) throws {
        self.connectionHandler = onConnection
        
        // Create listening socket
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw NSError(domain: "TCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        
        // Set SO_REUSEADDR
        var reuse = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<CInt>.size))
        
        // Bind
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        var addrBytes = sockaddr()
        memcpy(&addrBytes, &addr, MemoryLayout<sockaddr_in>.size)
        
        let bindResult = bind(listenFD, &addrBytes, socklen_t(MemoryLayout<sockaddr_in>.size))
        guard bindResult == 0 else {
            shutdown()
            throw NSError(domain: "TCPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }
        
        // Listen
        listen(listenFD, 1)
    }
    
    func acceptConnection() {
        guard listenFD >= 0 else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Outer loop: keep accepting clients so the host can reconnect
            while let self, self.listenFD >= 0 {
                var clientAddr = sockaddr()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr>.size)
                
                let fd = accept(self.listenFD, &clientAddr, &clientAddrLen)
                guard fd >= 0 else { break }
                self.clientFD = fd
                self.readMessages(fd: fd)
                close(fd)
                if fd == self.clientFD { self.clientFD = -1 }
            }
        }
    }
    
    /// Message framing: newline-terminated JSON header, then exactly
    /// `frameCount * 4` bytes of Float32 PCM. Repeats until EOF.
    private func readMessages(fd: CInt) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        
        while true {
            // Read header line (JSON, ends with \n)
            var headerData = Data()
            var byte: UInt8 = 0
            while true {
                let n = read(fd, &byte, 1)
                guard n > 0 else { return } // EOF / client gone
                headerData.append(byte)
                if byte == 0x0A { break }
            }
            
            // Decode header to learn the PCM payload length
            guard let header = try? JSONDecoder().decode(TabCaptureSession.TCPOutputHeader.self, from: headerData) else {
                continue // malformed header — skip to next message
            }
            let byteCount = header.frameCount * 4
            
            // Read exactly byteCount bytes of PCM
            var pcmData = Data(capacity: byteCount)
            while pcmData.count < byteCount {
                let toRead = min(buffer.count, byteCount - pcmData.count)
                let n = read(fd, &buffer, toRead)
                guard n > 0 else { return } // EOF mid-message
                pcmData.append(buffer, count: n)
            }
            
            connectionHandler?(headerData, pcmData)
        }
    }
    
    func stop() {
        shutdown()
    }
    
    func shutdown() {
        if clientFD >= 0 { _ = close(clientFD) }
        if listenFD >= 0 { _ = close(listenFD) }
        listenFD = -1
        clientFD = -1
    }
    
    deinit { shutdown() }
}
