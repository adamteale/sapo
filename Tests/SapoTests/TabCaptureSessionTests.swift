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
}
