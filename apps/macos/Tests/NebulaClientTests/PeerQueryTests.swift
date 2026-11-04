import Foundation
import XCTest
@testable import NebulaClient

final class PeerQueryTests: XCTestCase {
    private let peers = [
        KnownPeer(name: "node10", addresses: ["10.73.0.10"], pending: false),
        KnownPeer(name: "node2", addresses: ["10.73.0.2", "fd00:73::2"], pending: false),
        KnownPeer(name: "Café-Mac", addresses: ["10.73.0.3"], pending: false),
        KnownPeer(name: "设备四", addresses: ["10.73.0.4"], pending: true)
    ]
    func testNameAddressAndMultipleWordsMatchWithoutChangingSource() {
        XCTAssertEqual(PeerQuery.matching(peers, text: "NODE2 fd00", filter: .all).map(\.name), ["node2"])
        XCTAssertEqual(PeerQuery.matching(peers, text: "cafe", filter: .all).map(\.name), ["Café-Mac"])
        XCTAssertEqual(PeerQuery.matching(peers, text: "ＮＯＤＥ２", filter: .all).map(\.name), ["node2"])
        XCTAssertEqual(PeerQuery.matching(peers, text: "设备", filter: .all).map(\.name), ["设备四"])
        XCTAssertEqual(peers[0].name, "node10")
    }
    func testTunnelFiltersAreIndependentOfSearchAndSortNaturally() {
        let all = PeerQuery.matching(peers, text: " \n ", filter: .all)
        XCTAssertEqual(all.map(\.name), ["Café-Mac", "node2", "node10", "设备四"])
        XCTAssertEqual(PeerQuery.matching(peers, text: "10.73", filter: .active).count, 3)
        XCTAssertEqual(PeerQuery.matching(peers, text: "10.73", filter: .pending).map(\.name), ["设备四"])
        XCTAssertTrue(PeerQuery.matching(peers, text: "missing", filter: .all).isEmpty)
        XCTAssertTrue(PeerQuery.matching([], text: "", filter: .all).isEmpty)
    }
    func testLargeSnapshotsRetainEveryMatchingRecordForPaging() {
        let many = (0..<501).map { KnownPeer(name: "node\($0)", addresses: ["10.1.\($0 / 255).\($0 % 255)"], pending: $0.isMultiple(of: 2)) }
        let result = PeerQuery.matching(many, text: "node", filter: .all)
        XCTAssertEqual(result.count, 501)
        XCTAssertEqual(Set(result.map(\.id)).count, 501)
    }
    func testProfileNameNormalizationAndUTF8Boundary() {
        XCTAssertEqual(ProfileNameRules.normalized("  工作网络 \n"), "工作网络")
        for name in ["", "  ", "a\nb", "a\tb", "a\u{0}b", String(repeating: "中", count: 54)] {
            XCTAssertNotNil(ProfileNameRules.validationMessage(name))
        }
        XCTAssertNil(ProfileNameRules.validationMessage(String(repeating: "中", count: 53)+"a"))
        XCTAssertNil(ProfileNameRules.validationMessage("Office · Mac"))
    }
}
