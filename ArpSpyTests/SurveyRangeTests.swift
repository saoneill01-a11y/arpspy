import XCTest
@testable import ArpSpy

/// A site survey scans the organization's network, not whatever network this Mac happens to be on.
final class SurveyRangeTests: XCTestCase {
    let home = "192.168.1.0/24"

    func testNothingKnownUsesThisNetwork() {
        XCTAssertEqual(SurveyRange.suggested(thisNetwork: home, dhcpRange: "", nameServer: ""), home)
    }
    func testOnSiteKeepsThisNetwork() {
        XCTAssertEqual(SurveyRange.suggested(thisNetwork: "10.20.30.0/22", dhcpRange: "10.20.31.100-199", nameServer: ""), "10.20.30.0/22")
    }
    func testSubnetDHCPRangeIsUsed() {
        XCTAssertEqual(SurveyRange.suggested(thisNetwork: home, dhcpRange: "10.10.20.0/24", nameServer: "10.10.20.11"), "10.10.20.0/24")
    }
    func testStartEndDHCPRangeGivesItsSlash24() {
        XCTAssertEqual(SurveyRange.suggested(thisNetwork: home, dhcpRange: "10.0.0.100-10.0.0.199", nameServer: ""), "10.0.0.0/24")
    }
    func testNameServerWhenNoDHCPRange() {
        XCTAssertEqual(SurveyRange.suggested(thisNetwork: home, dhcpRange: "", nameServer: "172.16.8.20"), "172.16.8.0/24")
    }
    func testBadInputFallsBackToThisNetwork() {
        XCTAssertEqual(SurveyRange.suggested(thisNetwork: home, dhcpRange: "nope", nameServer: "dc01"), home)
    }
}
