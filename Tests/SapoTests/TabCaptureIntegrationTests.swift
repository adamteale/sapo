import XCTest
@testable import Sapo
import AVFoundation

/// Integration tests for TabCaptureSession with StemWriter.
///
/// These tests verify that TabCaptureSession can write audio data
/// to a stem file and that the file is valid.
final class TabCaptureIntegrationTests: XCTestCase {

    var tempDirectory: URL!
    var stemURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TabCaptureIntegrationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        stemURL = tempDirectory.appendingPathComponent("tab-stem.caf")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testTabCaptureSessionWritesValidStem() throws {
        // Create a TabCaptureSession with ALAC format
        let session = try TabCaptureSession.make(stemURL: stemURL, format: .alac, tabID: "123")

        // Simulate audio data: 1 second of 48kHz mono Float32 silence
        let frameCount: UInt32 = 48000
        let pcmData = Data(repeating: 0, count: Int(frameCount) * 4)

        // Write directly (simulating TCP callback)
        try session.writePCM(pcmData, frameCount: frameCount)

        // Verify file exists and is valid
        XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path))

        // Verify it's a valid CAF file by checking header
        let fileHandle = try XCTUnwrap(FileHandle(forReadingFrom: stemURL))
        let header = fileHandle.readData(ofLength: 12)
        XCTAssertEqual(header.count, 12)
        fileHandle.closeFile()
    }

    func testTabCaptureSessionHandlesPartialFrames() throws {
        let session = try TabCaptureSession.make(stemURL: stemURL, format: .alac, tabID: "456")

        // Write 0.5 seconds of audio
        let frameCount: UInt32 = 24000
        let pcmData = Data(repeating: 0, count: Int(frameCount) * 4)

        try session.writePCM(pcmData, frameCount: frameCount)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path))
    }

    func testTabCaptureSessionMultipleWrites() throws {
        let session = try TabCaptureSession.make(stemURL: stemURL, format: .alac, tabID: "789")

        // Write 3 chunks of 0.1 seconds each
        for _ in 0..<3 {
            let frameCount: UInt32 = 4800
            let pcmData = Data(repeating: 0, count: Int(frameCount) * 4)
            try session.writePCM(pcmData, frameCount: frameCount)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path))
    }

    func testTabCaptureSessionStopCleansUp() throws {
        let session = try TabCaptureSession.make(stemURL: stemURL, format: .alac, tabID: "999")

        // Write some data
        let frameCount: UInt32 = 1000
        let pcmData = Data(repeating: 0, count: Int(frameCount) * 4)
        try session.writePCM(pcmData, frameCount: frameCount)

        // Stop with reason
        session.stop(reason: "userDisconnected")

        // File should still exist (graceful shutdown)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path))
    }

    /// True end-to-end TCP loop: starts a real TabCaptureSession (real
    /// TCPServer on port 5678), connects a socket client speaking the same
    /// framing as SapoTabHost (newline-terminated JSON header + exact-length
    /// PCM per message), streams two chunks, then verifies the stem contains
    /// the summed frames at 48kHz mono.
    ///
    /// Requires port 5678 to be free (same as production default).
    func testTCPStreamingWritesStemFrames() throws {
        let session = try TabCaptureSession.make(stemURL: stemURL, format: .alac, tabID: "42")
        session.onLevel = { _ in }
        let ended = expectation(description: "onEnded fired")
        session.onEnded = { _ in ended.fulfill() }
        try session.start()

        // --- Client side: connect like SapoTabHost does ---
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(5678).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var addrBytes = sockaddr()
        memcpy(&addrBytes, &addr, MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(connect(fd, &addrBytes, socklen_t(MemoryLayout<sockaddr_in>.size)), 0, "connect to 127.0.0.1:5678 failed — is the port in use?")

        func sendFramed(_ tabId: String, _ pcm: Data) throws {
            let header = try JSONEncoder().encode(
                TabCaptureSession.TCPOutputHeader(tabId: tabId, sampleRate: 48000, frameCount: pcm.count / 4))
            var framed = header
            framed.append(0x0A) // newline terminator — same as the host
            framed.append(pcm)
            let sent = framed.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress?.assumingMemoryBound(to: CChar.self), framed.count, 0)
            }
            XCTAssertEqual(sent, framed.count, "short TCP send")
        }

        // Two chunks: 0.1s + 0.05s of silence = 7200 frames total
        try sendFramed("42", Data(repeating: 0, count: 4800 * 4))
        try sendFramed("42", Data(repeating: 0, count: 2400 * 4))

        // Let the server thread consume both messages
        Thread.sleep(forTimeInterval: 0.5)
        close(fd)

        session.stop(reason: "testDone")
        wait(for: [ended], timeout: 5.0)

        // --- Verify the written stem ---
        let file = try AVAudioFile(forReading: stemURL)
        XCTAssertEqual(file.length, 7200, "expected summed frame count")
        XCTAssertEqual(file.processingFormat.sampleRate, 48000, accuracy: 0.1)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
    }
}
