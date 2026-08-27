import Foundation
import AudioToolbox

/// Protocol for both CaptureChain and tab units.
/// Provides onLevel/onEnded callbacks, client format, and lifecycle methods.
protocol CaptureUnit: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onEnded: ((String) -> Void)? { get set }
    var clientFormat: AudioStreamBasicDescription { get }
    func start() throws
    func stop(reason: String)
}

/// Header preceding each PCM block on the capture TCP connection.
/// Written by SapoTabHost as newline-terminated JSON, followed by exactly
/// `frameCount * 4` bytes of Float32 mono PCM.
struct TabAudioHeader: Codable {
    let tabId: String
    let sampleRate: Int
    let frameCount: Int
}

/// One browser tab as reported by the extension's tablist pushes.
struct TabInfo: Codable, Equatable, Identifiable {
    let id: Int
    let title: String
    let audible: Bool
}

/// NDJSON payload pushed by the host to the registry port.
struct BrowserTabList: Codable {
    let tabs: [TabInfo]
}

extension StemWriter {
    /// Scope-safe raw Float32 mono PCM write. Builds the AudioBufferList and
    /// performs the write within one scope — a pointer to a stack-local
    /// buffer list must never outlive the call (dangling-pointer segfault).
    func write(pcm: Data, frameCount: UInt32) throws {
        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: 1,
                                                        mDataByteSize: UInt32(pcm.count),
                                                        mData: nil))
        try pcm.withUnsafeBytes { raw in
            abl.mBuffers.mData = UnsafeMutableRawPointer(mutating: raw.baseAddress)
            // &abl is valid for the duration of this synchronous write call.
            try write(&abl, frameCount: frameCount)
        }
    }
}

/// Single TCP server (port 5678) demultiplexing tab audio into per-tab stems.
///
/// The host sends one header+PCM message per audio chunk; the router looks
/// up the writer by `header.tabId`. Audio for tabs with no registered stem is
/// dropped — stems always match the user's selection. One router per
/// recording session; `TabStemUnit` adapts it into RecorderEngine's
/// per-source `CaptureUnit` world.
final class TabCaptureRouter {
    /// Fixed capture format: 32-bit float PCM, 48kHz, mono.
    static let pcmFormat = AudioStreamBasicDescription(
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

    var clientFormat: AudioStreamBasicDescription { Self.pcmFormat }

    private let tcpServer: TCPServer
    private var stems: [String: StemWriter] = [:]
    private var levelHandlers: [String: (Float) -> Void] = [:]
    private var endedHandlers: [String: (String) -> Void] = [:]
    private var lastLevelAt: [String: Double] = [:]
    private var started = false
    private var stopped = false
    private(set) var totalFrames: [String: UInt32] = [:]

    var activeTabCount: Int { stems.count }

    init(port: Int = 5678) {
        tcpServer = TCPServer(port: port)
    }

    /// Create (immediately, so the start manifest is crash-safe) the stem for
    /// a tab. Stems for tabs that never send audio remain empty files.
    func registerStem(tabID: String, stemURL: URL, format: StemFormat) throws {
        guard !stopped else { return }
        stems[tabID] = try StemWriter(url: stemURL, clientFormat: Self.pcmFormat, format: format)
    }

    /// Per-tab callbacks. onEnded is delivered on the main queue.
    func setHandlers(tabID: String, onLevel: ((Float) -> Void)?, onEnded: ((String) -> Void)?) {
        levelHandlers[tabID] = onLevel
        endedHandlers[tabID] = onEnded
    }

    func start() throws {
        guard !started, !stopped else { return }
        started = true
        try tcpServer.start { [weak self] headerData, pcmData in
            self?.handle(headerData: headerData, pcmData: pcmData)
        }
        tcpServer.acceptConnection()
    }

    func stop(reason: String) {
        guard !stopped else { return }
        stopped = true
        tcpServer.stop()
        endAllStems(reason: reason)
    }

    /// End a single tab's stem. When the last stem ends, the whole router
    /// shuts down (nobody else will connect with audio we care about).
    func endStem(tabID: String, reason: String) {
        guard let writer = stems.removeValue(forKey: tabID) else { return }
        writer.close()
        totalFrames.removeValue(forKey: tabID)
        let handler = endedHandlers.removeValue(forKey: tabID)
        levelHandlers.removeValue(forKey: tabID)
        lastLevelAt.removeValue(forKey: tabID)
        if stems.isEmpty {
            stop(reason: reason)
        } else {
            DispatchQueue.main.async { handler?(reason) }
        }
    }

    // MARK: - Internals

    private func endAllStems(reason: String) {
        let handlers = endedHandlers
        let ids = Array(stems.keys)
        for id in ids { stems[id]?.close() }
        stems = [:]
        endedHandlers = [:]
        levelHandlers = [:]
        lastLevelAt = [:]
        totalFrames = [:]
        DispatchQueue.main.async {
            for (_, handler) in handlers { handler(reason) }
        }
    }

    private func handle(headerData: Data, pcmData: Data) {
        guard let header = try? JSONDecoder().decode(TabAudioHeader.self, from: headerData),
              let writer = stems[header.tabId] else { return } // unknown tab → drop
        let frameCount = UInt32(pcmData.count / 4)
        do {
            try writer.write(pcm: pcmData, frameCount: frameCount)
            totalFrames[header.tabId, default: 0] += frameCount
            updateLevel(tabID: header.tabId, pcm: pcmData)
        } catch {
            print("Tab stem write error: \(error)")
            endStem(tabID: header.tabId, reason: "writeError")
        }
    }

    private func updateLevel(tabID: String, pcm: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastLevelAt[tabID] ?? 0) > 0.1 else { return } // ~10 Hz
        lastLevelAt[tabID] = now

        guard pcm.count >= 4 else { return }
        let samples = pcm.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress! }
        let sampleCount = pcm.count / 4
        var sum: Float = 0
        for i in 0..<sampleCount { let v = samples[i]; sum += v * v }
        let rms = sampleCount > 0 ? sqrt(sum / Float(sampleCount)) : 0
        let level = min(rms * 4, 1) // gain for visibility

        DispatchQueue.main.async { [weak self] in
            self?.levelHandlers[tabID]?(level)
        }
    }
}

/// One tab's presence in RecorderEngine's chains: a thin adapter over the
/// shared session router. `start()` is idempotent (router starts once);
/// `stop()` ends only this tab's stem.
final class TabStemUnit: CaptureUnit {
    var onLevel: ((Float) -> Void)? {
        didSet { router.setHandlers(tabID: tabID, onLevel: onLevel, onEnded: onEnded) }
    }
    var onEnded: ((String) -> Void)? {
        didSet { router.setHandlers(tabID: tabID, onLevel: onLevel, onEnded: onEnded) }
    }

    var clientFormat: AudioStreamBasicDescription { router.clientFormat }

    private let router: TabCaptureRouter
    let tabID: String

    init(router: TabCaptureRouter, tabID: String) {
        self.router = router
        self.tabID = tabID
    }

    func start() throws {
        try router.start()
    }

    func stop(reason: String) {
        router.endStem(tabID: tabID, reason: reason)
    }
}

/// Minimal TCP server for localhost capture traffic.
/// Framing: newline-terminated `TabAudioHeader` JSON, then exactly
/// `frameCount * 4` bytes of PCM, repeated; outer loop accepts reconnects.
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

        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw NSError(domain: "TCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var reuse = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<CInt>.size))

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
            throw NSError(domain: "TCPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed — port \(port) in use?"])
        }

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
            guard let header = try? JSONDecoder().decode(TabAudioHeader.self, from: headerData) else {
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

/// Always-on NDJSON server (port 5679) receiving tab-list pushes from
/// SapoTabHost. One JSON object per line: {"tabs":[{"id":…,"title":…,"audible":…}]}
/// The host reconnects for each push, so this must keep accepting clients.
final class TabRegistryServer {
    private var listenFD: CInt = -1
    private var clientFD: CInt = -1
    private let port: Int
    private var tabsHandler: (([TabInfo]) -> Void)?

    init(port: Int = 5679) {
        self.port = port
    }

    func start(onTabs: @escaping ([TabInfo]) -> Void) throws {
        self.tabsHandler = onTabs

        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw NSError(domain: "TabRegistryServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var reuse = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<CInt>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var addrBytes = sockaddr()
        memcpy(&addrBytes, &addr, MemoryLayout<sockaddr_in>.size)

        guard bind(listenFD, &addrBytes, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
            stop()
            throw NSError(domain: "TabRegistryServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed — port \(port) in use?"])
        }
        listen(listenFD, 1)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self, self.listenFD >= 0 {
                var clientAddr = sockaddr()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr>.size)
                let fd = accept(self.listenFD, &clientAddr, &clientAddrLen)
                guard fd >= 0 else { break }
                self.clientFD = fd
                self.readLines(fd: fd)
                close(fd)
                if fd == self.clientFD { self.clientFD = -1 }
            }
        }
    }

    /// Read newline-delimited JSON objects until EOF; each complete line is a
    /// tab-list update.
    private func readLines(fd: CInt) {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            for i in 0..<n {
                line.append(buffer[i])
                if buffer[i] == 0x0A {
                    if let list = try? JSONDecoder().decode(BrowserTabList.self, from: line) {
                        tabsHandler?(list.tabs)
                    }
                    line = Data()
                }
            }
        }
    }

    func stop() {
        if clientFD >= 0 { _ = close(clientFD) }
        if listenFD >= 0 { _ = close(listenFD) }
        listenFD = -1
        clientFD = -1
    }

    deinit { stop() }
}
