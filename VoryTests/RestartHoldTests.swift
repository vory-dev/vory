import Foundation
import Testing
@testable import VoryCore

/// A gateway that's restarting reads as restarting: Hermes answers REST 503 gateway_not_ready and closes an open
/// socket 1013, refuses while no process listens, then answers an upgrade 403 before accepting it. A refused sign-in
/// is never hidden by it, and REST waits a restart out.
@Suite struct RestartHoldTests {
    static let notReady = HermesAPIError.http(status: 503, detail: "gateway_not_ready")
    static let upgrade403 = SocketError.refused(status: 403, location: nil, cloudflare: false, html: false)

    @Test func aRestartsSignsAreSaidAsRestarting() {
        #expect(ConnectProblem.of(Self.notReady) == .restarting)
        #expect(ConnectProblem.of(SocketError.closed(code: 1013, reason: "")) == .restarting)
        #expect(ConnectProblem.of(HermesAPIError.http(status: 503, detail: "maintenance")) == .http(status: 503), "another 503 read as a restart")
        #expect(ConnectProblem.of(Self.upgrade403) == .http(status: 403), "a 403 read as a restart with no sign")
    }

    /// One failed attempt: what it names, and the hold after it.
    struct Attempt: Sendable, CustomTestStringConvertible {
        var name: String
        var error: any Error
        var ticketed = false
        var ticketMetNotReady = false
        /// Seconds since the restart's last sign; nil for none.
        var since: Double?
        var named: ConnectProblem?
        /// Whether the hold goes on (from the same sign), starts (now), or ends.
        var hold: Hold
        var testDescription: String { name }
    }
    enum Hold: Sendable { case goesOn, startsNow, ends }

    static let attempts: [Attempt] = [
        // A sign-in refusal is never the restart, and ends the hold: its own words show.
        .init(name: "a 4401 inside the hold", error: SocketError.closed(code: 4401, reason: ""), since: 30, named: nil, hold: .ends),
        .init(name: "a 401 on the ticket inside the hold", error: HermesAPIError.unauthorized(""), ticketed: true, since: 30, named: nil, hold: .ends),
        .init(name: "an ended session inside the hold", error: HermesAPIError.sessionExpired, ticketed: true, since: 30, named: nil, hold: .ends),
        .init(name: "a 4403 inside the hold", error: SocketError.closed(code: 4403, reason: ""), since: 30, named: nil, hold: .ends),
        .init(name: "a call's refusal inside the hold", error: RPCError(code: 4001, message: "permission_denied"), since: 30, named: nil, hold: .ends),
        // The signs themselves.
        .init(name: "a 1013 close", error: SocketError.closed(code: 1013, reason: "draining"), named: .restarting, hold: .startsNow),
        .init(name: "the ticket met gateway_not_ready", error: notReady, ticketed: true, ticketMetNotReady: true, since: 30, named: .restarting, hold: .startsNow),
        // A session token's mode: no ticket call to tell by, and a wrong token is refused 4401 after the accept.
        .init(name: "a token's 403 inside the hold", error: upgrade403, since: 30, named: .restarting, hold: .goesOn),
        .init(name: "a token's 403 after the hold", error: upgrade403, since: 121, named: .http(status: 403), hold: .ends),
        .init(name: "a token's 403 with no sign", error: upgrade403, named: .http(status: 403), hold: .ends),
        // A ticket's mode: a 403 after a ticket the gateway minted is the gateway's own.
        .init(name: "a 403 after a minted ticket", error: upgrade403, ticketed: true, since: 30, named: .http(status: 403), hold: .ends),
        .init(name: "a 403 after a ticket that met gateway_not_ready", error: upgrade403, ticketed: true, ticketMetNotReady: true, since: 30,
              named: .restarting, hold: .goesOn),
        // The rest.
        .init(name: "no listener inside the hold", error: URLError(.cannotConnectToHost), since: 30, named: .restarting, hold: .goesOn),
        .init(name: "no listener with no sign", error: URLError(.cannotConnectToHost), named: .noAnswer, hold: .ends),
        .init(name: "another 503 inside the hold", error: HermesAPIError.http(status: 503, detail: "maintenance"), since: 30,
              named: .http(status: 503), hold: .goesOn),
    ]

    @Test(arguments: attempts)
    func theRestartHold(_ a: Attempt) {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let sign = a.since.map { now.addingTimeInterval(-$0) }
        let r = GatewaySocket.problem(for: a.error, ticketed: a.ticketed, ticketMetNotReady: a.ticketMetNotReady, restartSeenAt: sign, now: now)
        #expect(r.problem == a.named)
        switch a.hold {
        case .goesOn: #expect(r.restartSeenAt == sign, "the hold didn't go on from its sign")
        case .startsNow: #expect(r.restartSeenAt == now, "the hold didn't start")
        case .ends: #expect(r.restartSeenAt == nil, "the hold went on")
        }
    }

    @Test func aRestartIsWaitedOutForTwentySeconds() {
        #expect(HermesAPI.restartWaits(budget: HermesAPI.restartBudget) == [1, 2, 3, 5, 8])
        #expect(HermesAPI.restartWaits(budget: 10) == [1, 2, 3])
        #expect(Self.notReady.errorDescription == "The gateway is restarting. Try again in a moment.")
    }
}
