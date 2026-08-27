import XCTest
@testable import Sapo
import AVFoundation

/// Multi-tab router integration: one TCP server, per-tab stems, demux by
/// header tabId — the same path RecorderEngine drives during a session.
final class TabCaptureRouterTests: XCTestCase {

    var tempDirectory: URL!
    var stemA: URL!
    var stemB: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TabCaptureRouterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        stemA = tempDirectory.appendingPathComponent("tab-a.caf")
        stemB = tempDirectory.appendingPathComponent("tab-b.caf")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    /// Send one framed message (header line + exact PCM) like the host does.
    private func sendFramed(_ fd: CInt, tabId: String, pcm: Data) throws {
        let header = try JSONEncoder().encode(
            TabAudioHeader(tabId: tabId, sampleRate: 48000, frameCount: pcm.count / 4))
        var framed = header
        framed.append(0x0A)
        framed.append(pcm)
        let sent = framed.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress?.assumingMemoryBound(to: CChar.self), framed.count, 0)
        }
        XCTAssertEqual(sent, framed.count, "short TCP send")
    }

    private func connectLocal(port: Int = 5678) throws -> CInt {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var addrBytes = sockaddr()
        memcpy(&addrBytes, &addr, MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(Darwin.connect(fd, &addrBytes, socklen_t(MemoryLayout<sockaddr_in>.size)), 0,
                       "connect failed — port \(port) in use?")
        return fd
    }

    /// Two tabs stream over ONE connection; each stem gets exactly its own
    /// frames (demux by header tabId).
    func testTwoTabsDemuxIntoSeparateStems() throws {
        let router = TabCaptureRouter()
        try router.registerStem(tabID: "11", stemURL: stemA, format: .alac)
        try router.registerStem(tabID: "22", stemURL: stemB, format: .alac)
        try router.start()

        let fd = try connectLocal()
        // tab 11: 0.1s; tab 22: 0.05s; interleaved
        try sendFramed(fd, tabId: "11", pcm: Data(repeating: 0, count: 4800 * 4))
        try sendFramed(fd, tabId: "22", pcm: Data(repeating: 0, count: 2400 * 4))
        try sendFramed(fd, tabId: "11", pcm: Data(repeating: 0, count: 4800 * 4))

        Thread.sleep(forTimeInterval: 0.5)
        close(fd)
        router.stop(reason: "testDone")

        let a = try AVAudioFile(forReading: stemA)
        let b = try AVAudioFile(forReading: stemB)
        XCTAssertEqual(a.length, 9600, "tab 11 frames")
        XCTAssertEqual(b.length, 2400, "tab 22 frames")
        XCTAssertEqual(a.processingFormat.sampleRate, 48000, accuracy: 0.1)
        XCTAssertEqual(a.processingFormat.channelCount, 1)
    }

    /// Audio for a tab with no registered stem is dropped, not misrouted.
    func testUnknownTabAudioIsDropped() throws {
        let router = TabCaptureRouter()
        try router.registerStem(tabID: "11", stemURL: stemA, format: .alac)
        try router.start()

        let fd = try connectLocal()
        try sendFramed(fd, tabId: "999", pcm: Data(repeating: 0, count: 4800 * 4))
        try sendFramed(fd, tabId: "11", pcm: Data(repeating: 0, count: 2400 * 4))
        Thread.sleep(forTimeInterval: 0.4)
        close(fd)
        router.stop(reason: "testDone")

        let a = try AVAudioFile(forReading: stemA)
        XCTAssertEqual(a.length, 2400, "only the registered tab's frames land")
    }

    /// Ending one tab leaves the other recording; ending the last stops the
    /// router (server down, all callbacks delivered).
    func testEndStemPerTabAndAutoStopOnLast() throws {
        let router = TabCaptureRouter()
        try router.registerStem(tabID: "11", stemURL: stemA, format: .alac)
        try router.registerStem(tabID: "22", stemURL: stemB, format: .alac)
        try router.start()

        var endedA: [String] = []
        let endedAExpectation = expectation(description: "stem A ended")
        router.setHandlers(tabID: "11",
                           onLevel: nil,
                           onEnded: { reason in endedA.append(reason); endedAExpectation.fulfill() })

        router.endStem(tabID: "11", reason: "tabClosed")
        wait(for: [endedAExpectation], timeout: 3.0)
        XCTAssertEqual(endedA, ["tabClosed"])
        XCTAssertEqual(router.activeTabCount, 1, "tab 22 still active")

        // Last stem end shuts the router down; a second stop must be a no-op.
        router.endStem(tabID: "22", reason: "sessionEnd")
        router.stop(reason: "sessionEnd") // idempotency — must not double-fire
        XCTAssertEqual(router.activeTabCount, 0)
    }

    /// TabStemUnit maps one tab onto the CaptureUnit world: stop() ends only
    /// that tab; the shared router survives for the others.
    func testTabStemUnitStopsOnlyOwnTab() throws {
        let router = TabCaptureRouter()
        try router.registerStem(tabID: "11", stemURL: stemA, format: .alac)
        try router.registerStem(tabID: "22", stemURL: stemB, format: .alac)
        try router.start()

        let unitA = TabStemUnit(router: router, tabID: "11")
        let unitB = TabStemUnit(router: router, tabID: "22")
        var endedB: [String] = []
        let exp = expectation(description: "B ended on session stop")
        unitB.onEnded = { reason in endedB.append(reason); exp.fulfill() }
        unitA.onEnded = { _ in } // no-op; must not fire on A's own stop

        unitA.stop(reason: "midSession") // ends only tab 11
        XCTAssertEqual(router.activeTabCount, 1)

        router.stop(reason: "sessionEnd") // fires B (and the dead A is gone)
        wait(for: [exp], timeout: 3.0)
        XCTAssertEqual(endedB, ["sessionEnd"])
        XCTAssertEqual(unitA.clientFormat.mSampleRate, 48000, accuracy: 0.1)
    }
}

/// Registry server: NDJSON lines → [TabInfo] callbacks.
final class TabRegistryServerTests: XCTestCase {
    func testNDJSONLinesProduceTabCallbacks() throws {
        let server = TabRegistryServer(port: 5679)
        defer { server.stop() }

        var received: [[TabInfo]] = []
        let exp = expectation(description: "tablist received")
        exp.expectedFulfillmentCount = 2
        try server.start { tabs in
            received.append(tabs)
            exp.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2) // let accept() spin up

        // Client: connect, write two NDJSON lines, close.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(5679).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var addrBytes = sockaddr()
        memcpy(&addrBytes, &addr, MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(Darwin.connect(fd, &addrBytes, socklen_t(MemoryLayout<sockaddr_in>.size)), 0)

        let line1 = #"{"tabs":[{"id":1,"title":"YouTube — Song","audible":true}]}"#.data(using: .utf8)! + Data([0x0A])
        let line2 = #"{"tabs":[]}"#.data(using: .utf8)! + Data([0x0A])
        for line in [line1, line2] {
            _ = line.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress?.assumingMemoryBound(to: CChar.self), line.count, 0)
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        close(fd)
        wait(for: [exp], timeout: 3.0)

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].first?.id, 1)
        XCTAssertEqual(received[0].first?.audible, true)
        XCTAssertEqual(received[1], [])
    }
}
