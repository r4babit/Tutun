import XCTest
@testable import TutunSystem

final class ConnectivityCheckDNSTests: XCTestCase {
    private func question(_ name: String, type: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [18, 52, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        return bytes + [0, 0, type, 0, 1]
    }

    func testOnlyAppleChecksGetLoopbackAddresses() throws {
        let v4 = try XCTUnwrap(ConnectivityCheckDNS.response(question("CAPTIVE.apple.com", type: 1)))
        XCTAssertEqual(Array(v4.prefix(2)), [18, 52])
        XCTAssertEqual(Array(v4.suffix(4)), [127, 0, 0, 1])
        let v6 = try XCTUnwrap(ConnectivityCheckDNS.response(question("netcts.cdn-apple.com", type: 28)))
        XCTAssertEqual(Array(v6.suffix(16)), Array(repeating: 0, count: 15) + [1])
        XCTAssertNil(ConnectivityCheckDNS.response(question("other.apple.com", type: 1)))
        XCTAssertNil(ConnectivityCheckDNS.response(Array(question("captive.apple.com", type: 1).dropLast())))
    }
}
