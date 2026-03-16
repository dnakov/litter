import XCTest
@testable import Litter

final class NetworkDiscoveryTests: XCTestCase {
    func testTailscaleAvailabilitySurfacesNoticeWhenAppIsInstalled() {
        let availability = TailscaleAvailability(appInstalled: true, likelyActiveTunnel: false)

        XCTAssertTrue(availability.shouldSurfaceDiscoveryNotice)
    }

    func testTailscaleAvailabilitySurfacesNoticeWhenTunnelLooksActive() {
        let availability = TailscaleAvailability(appInstalled: false, likelyActiveTunnel: true)

        XCTAssertTrue(availability.shouldSurfaceDiscoveryNotice)
    }

    func testTailscaleAvailabilitySuppressesNoticeWhenAppIsMissingAndTunnelIsInactive() {
        let availability = TailscaleAvailability(appInstalled: false, likelyActiveTunnel: false)

        XCTAssertFalse(availability.shouldSurfaceDiscoveryNotice)
    }

    func testParseTailscalePeerCandidatesFiltersOfflineAndNonIPv4Peers() throws {
        let data = """
        {
          "Peer": {
            "peer-1": {
              "Online": true,
              "HostName": "mac-mini",
              "TailscaleIPs": ["fd7a:115c:a1e0::1", "100.64.0.12"]
            },
            "peer-2": {
              "Online": false,
              "HostName": "offline-host",
              "TailscaleIPs": ["100.64.0.13"]
            },
            "peer-3": {
              "Online": true,
              "DNSName": "ipv6-only.example.ts.net.",
              "TailscaleIPs": ["fd7a:115c:a1e0::2"]
            }
          }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://100.100.100.100/localapi/v0/status")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        let peers = try NetworkDiscovery.parseTailscalePeerCandidates(data: data, response: response)

        XCTAssertEqual(peers, [TailscalePeerIdentity(ip: "100.64.0.12", name: "mac-mini")])
    }

    func testParseTailscalePeerCandidatesRejectsHtmlSurface() {
        let data = """
        <!doctype html>
        <html><body>Tailscale web interface</body></html>
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://100.100.100.100/localapi/v0/status")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!

        XCTAssertThrowsError(
            try NetworkDiscovery.parseTailscalePeerCandidates(data: data, response: response)
        )
    }

    func testParseTailscalePeerCandidatesRejectsDeviceStatusPayloadWithoutPeerList() {
        let data = """
        {
          "Status": "Running",
          "DeviceName": "sigkittens-mac-studio",
          "IPv4": "100.113.43.109"
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://100.100.100.100/localapi/v0/status")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        XCTAssertThrowsError(
            try NetworkDiscovery.parseTailscalePeerCandidates(data: data, response: response)
        )
    }
}
