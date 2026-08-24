import XCTest
@testable import Sapo
import AVFoundation

/// Tests for TCPOutputHeader and TabCaptureSession's TCP parsing.
final class TabCaptureSessionParsingTests: XCTestCase {

    func testTCPOutputHeaderDecodesValidJSON() throws {
        let json = """
        {"tabId":"123","sampleRate":48000,"frameCount":1024}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let header = try JSONDecoder().decode(TabCaptureSession.TCPOutputHeader.self, from: data)
        XCTAssertEqual(header.tabId, "123")
        XCTAssertEqual(header.sampleRate, 48000)
        XCTAssertEqual(header.frameCount, 1024)
    }

    func testTCPOutputHeaderRejectsInvalidJSON() throws {
        let json = "{\"tabId\":\"123\",\"sampleRate\":48000" // missing closing brace
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(TabCaptureSession.TCPOutputHeader.self, from: data))
    }

    func testTCPOutputHeaderHandlesCompleteFields() throws {
        let json = "{\"tabId\":\"123\",\"sampleRate\":48000,\"frameCount\":1024}"
        let data = try XCTUnwrap(json.data(using: .utf8))
        let header = try JSONDecoder().decode(TabCaptureSession.TCPOutputHeader.self, from: data)
        XCTAssertEqual(header.tabId, "123")
        XCTAssertEqual(header.sampleRate, 48000)
        XCTAssertEqual(header.frameCount, 1024)
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
