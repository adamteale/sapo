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
                let bufferList = pcmDataToBufferList(pcmData)
                try self.stemWriter.write(bufferList, frameCount: frameCount)
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
    
    func pcmDataToBufferList(_ data: Data) -> UnsafePointer<AudioBufferList> {
        // Create a simple AudioBufferList from the PCM data
        // SAFETY: ExtAudioFileWrite reads synchronously, so the pointer is valid
        // for the duration of the write call. We use withUnsafePointer to satisfy
        // Swift's temporary pointer rules.
        var result: UnsafePointer<AudioBufferList>!
        data.withUnsafeBytes { raw in
            var abl = AudioBufferList(mNumberBuffers: 1,
                                      mBuffers: AudioBuffer(mNumberChannels: 1,
                                                            mDataByteSize: UInt32(data.count),
                                                            mData: UnsafeMutableRawPointer(mutating: raw.baseAddress)))
            result = withUnsafePointer(to: &abl) { $0 }
        }
        return result
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
        
        var clientAddr = sockaddr()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr>.size)
        
        clientFD = accept(listenFD, &clientAddr, &clientAddrLen)
        guard clientFD >= 0 else { return }
        
        // Read messages: JSON header (variable length, ends with newline) + raw PCM
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            var headerData = Data()
            var pcmData = Data()
            
            // Read header (JSON, ends with newline)
            while true {
                var byte: UInt8 = 0
                let bytesRead = read(self.clientFD, &byte, 1)
                guard bytesRead > 0 else { break }
                headerData.append(byte)
                if byte == 0x0A { break } // newline
            }
            
            // Read remaining data (PCM)
            var buffer = [UInt8](repeating: 0, count: 1024 * 4096)
            while true {
                let bytesRead = read(self.clientFD, &buffer, buffer.count)
                guard bytesRead > 0 else { break }
                pcmData.append(buffer, count: bytesRead)
            }
            
            self.connectionHandler?(headerData, pcmData)
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
