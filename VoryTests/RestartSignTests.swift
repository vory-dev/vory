import Foundation
import Testing
@testable import VoryCore

/// A session token's 403 upgrade with no hold running asks the gateway's own status read before it is named: Hermes
/// closes an upgrade before accepting it, a 403 to the client, while it isn't ready or is draining, and a token's mode
/// has no ticket call to tell by. Only the gateway's own word starts the hold; without it the 403 stays the gateway's own.
@Suite struct RestartSignTests {
    static let upgrade403 = SocketError.refused(status: 403, location: nil, cloudflare: false, html: false)
    static let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func aTokensRefusedUpgradeAsksTheStatus() {
        #expect(GatewaySocket.asksStatus(for: Self.upgrade403, ticketed: false, restartSeenAt: nil, now: Self.now))
        #expect(GatewaySocket.asksStatus(for: Self.upgrade403, ticketed: false, restartSeenAt: Self.now.addingTimeInterval(-121), now: Self.now),
                "a 403 after the hold ended didn't ask")
        // Inside the hold the 403 is the restart already; a ticket's mode has its ticket call to tell by.
        #expect(!GatewaySocket.asksStatus(for: Self.upgrade403, ticketed: false, restartSeenAt: Self.now.addingTimeInterval(-30), now: Self.now))
        #expect(!GatewaySocket.asksStatus(for: Self.upgrade403, ticketed: true, restartSeenAt: nil, now: Self.now))
        // Cloudflare's 403, a web page, another status, a sign-in refusal: none asks.
        #expect(!GatewaySocket.asksStatus(for: SocketError.refused(status: 403, location: nil, cloudflare: true, html: true),
                                          ticketed: false, restartSeenAt: nil, now: Self.now))
        #expect(!GatewaySocket.asksStatus(for: SocketError.refused(status: 403, location: nil, cloudflare: false, html: true),
                                          ticketed: false, restartSeenAt: nil, now: Self.now))
        #expect(!GatewaySocket.asksStatus(for: SocketError.refused(status: 404, location: nil, cloudflare: false, html: false),
                                          ticketed: false, restartSeenAt: nil, now: Self.now))
        #expect(!GatewaySocket.asksStatus(for: SocketError.closed(code: 4401, reason: ""), ticketed: false, restartSeenAt: nil, now: Self.now))
    }

    @Test func theStatusReadStaysOnTheGatewaysAddress() throws {
        let local = try #require(GatewaySocket.statusRequest(upgradeURL: URL(string: "ws://127.0.0.1:9129/api/ws?token=secret-token")!,
                                                             headers: [:]))
        #expect(local.url?.absoluteString == "http://127.0.0.1:9129/api/status")
        #expect(local.httpMethod == "GET")
        #expect(local.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(!(local.url?.absoluteString.contains("secret-token") ?? true), "the session token went into the status read")
        let behind = try #require(GatewaySocket.statusRequest(upgradeURL: URL(string: "wss://gw.example.com/hermes/api/ws?token=t")!,
                                                              headers: ["CF-Access-Client-Id": "id"]))
        #expect(behind.url?.absoluteString == "https://gw.example.com/hermes/api/status")
        #expect(behind.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id", "the address's own Access header was dropped")
        #expect(GatewaySocket.statusRequest(upgradeURL: URL(string: "https://gw.example.com/api/ws")!, headers: [:]) == nil)
        #expect(GatewaySocket.statusRequest(upgradeURL: URL(string: "ws://127.0.0.1:9129/api/plugins/kanban/events")!, headers: [:]) == nil)
    }

    @Test func hermesOwnWordsReadAsRestarting() {
        func body(_ s: String) -> Data { Data(s.utf8) }
        #expect(GatewaySocket.saysRestarting(status: 503, body: body(#"{"error": "gateway_not_ready", "state": "draining"}"#)))
        #expect(GatewaySocket.saysRestarting(status: 503, body: body(#"{"error": "gateway_not_ready", "state": "starting"}"#)))
        #expect(GatewaySocket.saysRestarting(status: 200, body: body(#"{"gateway_state": "draining", "gateway_running": true}"#)))
        #expect(!GatewaySocket.saysRestarting(status: 200, body: body(#"{"gateway_state": "running", "gateway_running": true}"#)))
        #expect(!GatewaySocket.saysRestarting(status: 503, body: body(#"{"error": "maintenance"}"#)))
        #expect(!GatewaySocket.saysRestarting(status: 401, body: body(#"{"error": "gateway_not_ready"}"#)))
        #expect(!GatewaySocket.saysRestarting(status: 503, body: body("<html>Bad gateway</html>")))
    }

    @Test func aTokens403TheStatusConfirmsStartsTheHold() {
        let r = GatewaySocket.problem(for: Self.upgrade403, ticketed: false, ticketMetNotReady: false, statusSaysRestarting: true,
                                      restartSeenAt: nil, now: Self.now)
        #expect(r.problem == .restarting)
        #expect(r.restartSeenAt == Self.now, "the hold didn't start")
    }

    /// The gateway's own word is the only way in: a 403 without it, a ticket's 403, and a refused sign-in read as they
    /// always have, whatever the status read said.
    @Test func a403WithNoRestartSignStaysTheGatewaysOwn() {
        let none = GatewaySocket.problem(for: Self.upgrade403, ticketed: false, ticketMetNotReady: false, statusSaysRestarting: false,
                                         restartSeenAt: nil, now: Self.now)
        #expect(none.problem == .http(status: 403))
        #expect(none.restartSeenAt == nil)
        let ticket = GatewaySocket.problem(for: Self.upgrade403, ticketed: true, ticketMetNotReady: false, statusSaysRestarting: true,
                                           restartSeenAt: nil, now: Self.now)
        #expect(ticket.problem == .http(status: 403))
        #expect(ticket.restartSeenAt == nil)
        let signIn = GatewaySocket.problem(for: SocketError.closed(code: 4401, reason: ""), ticketed: false, ticketMetNotReady: false,
                                           statusSaysRestarting: true, restartSeenAt: nil, now: Self.now)
        #expect(signIn.problem == nil, "a refused sign-in was named as a restart")
        #expect(signIn.restartSeenAt == nil)
    }
}
