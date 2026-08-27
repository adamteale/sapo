import XCTest
@testable import Sapo

final class TabCaptureSessionParsingTests: XCTestCase {
    func testTCPOutputHeaderDecodesValidJSON() throws {
        let json = """
        {"tabId":"123","sampleRate":48000,"frameCount":1024}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let header = try JSONDecoder().decode(TabAudioHeader.self, from: data)
        XCTAssertEqual(header.tabId, "123")
        XCTAssertEqual(header.sampleRate, 48000)
        XCTAssertEqual(header.frameCount, 1024)
    }

    func testTCPOutputHeaderRejectsInvalidJSON() throws {
        let json = "{\"tabId\":\"123\",\"sampleRate\":48000" // missing closing brace
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(TabAudioHeader.self, from: data))
    }

    func testTCPOutputHeaderHandlesCompleteFields() throws {
        let json = "{\"tabId\":\"123\",\"sampleRate\":48000,\"frameCount\":1024}"
        let data = try XCTUnwrap(json.data(using: .utf8))
        let header = try JSONDecoder().decode(TabAudioHeader.self, from: data)
        XCTAssertEqual(header.tabId, "123")
        XCTAssertEqual(header.sampleRate, 48000)
        XCTAssertEqual(header.frameCount, 1024)
    }

    func testTabListDecodes() throws {
        let json = """
        {"tabs":[{"id":7,"title":"A very long tab title","audible":false},{"id":8,"title":"x","audible":true}]}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let list = try JSONDecoder().decode(BrowserTabList.self, from: data)
        XCTAssertEqual(list.tabs.count, 2)
        XCTAssertEqual(list.tabs[0].id, 7)
        XCTAssertEqual(list.tabs[1].audible, true)
    }
}
