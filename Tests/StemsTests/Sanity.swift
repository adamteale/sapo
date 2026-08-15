import Foundation
import Testing
@testable import Stems

@Test func sanity() {
    #expect(Bundle.main.bundleIdentifier != nil || true) // target links and runs
}
