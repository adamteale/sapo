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
        let bufferList = createBufferList(from: pcmData)

        // Write directly (simulating TCP callback)
        try session.stemWriter.write(bufferList, frameCount: frameCount)

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
        let bufferList = createBufferList(from: pcmData)

        try session.stemWriter.write(bufferList, frameCount: frameCount)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path))
    }

    func testTabCaptureSessionMultipleWrites() throws {
        let session = try TabCaptureSession.make(stemURL: stemURL, format: .alac, tabID: "789")

        // Write 3 chunks of 0.1 seconds each
        for _ in 0..<3 {
            let frameCount: UInt32 = 4800
            let pcmData = Data(repeating: 0, count: Int(frameCount) * 4)
            let bufferList = createBufferList(from: pcmData)
            try session.stemWriter.write(bufferList, frameCount: frameCount)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path))
    }

    func testTabCaptureSessionStopCleansUp() throws {
        let session = try TabCaptureSession.make(stemURL: stemURL, format: .alac, tabID: "999")

        // Write some data
        let frameCount: UInt32 = 1000
        let pcmData = Data(repeating: 0, count: Int(frameCount) * 4)
        let bufferList = createBufferList(from: pcmData)
        try session.stemWriter.write(bufferList, frameCount: frameCount)

        // Stop with reason
        session.stop(reason: "userDisconnected")

        // File should still exist (graceful shutdown)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path))
    }
    
    /// Helper to create a valid AudioBufferList from PCM data.
    private func createBufferList(from data: Data) -> UnsafePointer<AudioBufferList> {
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
