import Foundation
import Testing
@testable import VoryCore

/// Hermes's session authority's two chat events: a replay gap (this socket's subscription to the chat ended, the socket
/// still up), which the chat answers by attaching again, paced; and session.updated, an applied edit's receipt, whose
/// fences and stored title the chat takes.
@MainActor @Suite struct ReplayGapTests {
    let t0 = Date(timeIntervalSince1970: 3_000_000)

    @Test func aFirstGapAttachesAgainNow() {
        let r = GapPacing.decision(lastGapAt: nil, streak: 0, inFlight: false, now: t0)
        #expect(r.decision == .now)
        #expect(r.streak == 1)
    }

    @Test func aGapSoonAfterTheLastWaitsTheReconnectSchedulesDelay() {
        let second = GapPacing.decision(lastGapAt: t0, streak: 1, inFlight: false, now: t0.addingTimeInterval(1))
        #expect(second.decision == .after(2))
        #expect(second.streak == 2)
        let third = GapPacing.decision(lastGapAt: t0, streak: 2, inFlight: false, now: t0.addingTimeInterval(10))
        #expect(third.decision == .after(5))
        let sixth = GapPacing.decision(lastGapAt: t0, streak: 5, inFlight: false, now: t0.addingTimeInterval(20))
        #expect(sixth.decision == .after(30))
    }

    @Test func aGapWhileOneIsInFlightMarksOneMore() {
        let r = GapPacing.decision(lastGapAt: t0, streak: 1, inFlight: true, now: t0.addingTimeInterval(1))
        #expect(r.decision == .afterTheOneInFlight, "a second re-attach would run beside the first")
        #expect(r.streak == 2)
    }

    @Test func twoGapsASecondApartGiveOneNowAndOneLater() {
        let first = GapPacing.decision(lastGapAt: nil, streak: 0, inFlight: false, now: t0)
        #expect(first.decision == .now)
        // The first's re-attach is in flight when the second comes.
        let second = GapPacing.decision(lastGapAt: t0, streak: first.streak, inFlight: true, now: t0.addingTimeInterval(1))
        #expect(second.decision != .now, "two re-attaches at once")
        #expect(second.decision == .afterTheOneInFlight)
    }

    @Test func aQuietWindowStartsTheStretchAgain() {
        let r = GapPacing.decision(lastGapAt: t0, streak: 4, inFlight: false, now: t0.addingTimeInterval(GapPacing.window + 1))
        #expect(r.decision == .now)
        #expect(r.streak == 1)
    }

    /// A chat on a runtime that never connects, with the wire's authority as given.
    func chat(authority: Bool) throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        rt.sessionAuthority = authority
        let c = ChatSession(runtime: rt, storedID: "stored-1", title: "Old")
        rt.registry.add(c)
        return c
    }

    func updated() -> GatewayEvent {
        GatewayEvent(type: "session.updated", sessionID: "s1",
                     payload: .object(["session_id": .string("s1"), "operation": .string("rename"), "revision": .number(7),
                                       "execution_generation": .number(3), "title": .string("New")]), seq: nil)
    }

    @Test func aSessionUpdatedGivesTheChatItsFencesAndTitle() throws {
        let c = try chat(authority: true)
        c.handle(event: updated())
        #expect(c.revision == 7)
        #expect(c.executionGeneration == 3)
        #expect(c.title == "New")
    }

    @Test func aSessionUpdatedIsLeftAloneOnTheLegacyWire() throws {
        let c = try chat(authority: false)
        c.handle(event: updated())
        #expect(c.revision == nil)
        #expect(c.executionGeneration == nil)
        #expect(c.title == "Old")
    }

    /// The resumes a set of chats sent, and how many were out at once.
    @MainActor final class Resumes {
        var count = 0
        var inFlight = 0
        var maxInFlight = 0
    }

    /// One slow socket can end every chat's subscription at once. The chats off screen re-attach through the runtime's
    /// pass, one resume in flight at a time, as after a reconnect; a chat on screen re-attaches by itself at once.
    @Test func gapsForManyChatsAtOnceSendOneOffScreenResumeAtATime() async throws {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        let offScreen = Resumes(), onScreen = Resumes()
        var chats: [ChatSession] = []
        for i in 0..<6 {
            let c = ChatSession(runtime: rt, storedID: "s\(i)", title: nil)
            let log = i == 0 ? onScreen : offScreen
            c.gatewayStandIn = { method, _ in
                guard method == "session.resume" else { return .object([:]) }
                log.count += 1
                log.inFlight += 1
                log.maxInFlight = max(log.maxInFlight, log.inFlight)
                defer { log.inFlight -= 1 }
                for _ in 0..<5 { await Task.yield() }
                return .object(["session_id": .string("rt\(i)"), "running": false, "messages": .array([])])
            }
            rt.registry.add(c)
            chats.append(c)
        }
        chats[0].cameOnScreen()
        for (i, c) in chats.enumerated() {
            c.handle(event: GatewayEvent(type: "session.replay_gap", sessionID: "rt\(i)",
                                         payload: .object(["replay_epoch": .number(1), "latest_seq": .number(40)]), seq: nil))
        }
        for _ in 0..<200 where offScreen.count < 5 || onScreen.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(onScreen.count == 1, "the chat on screen re-attached \(onScreen.count) times")
        #expect(offScreen.count == 5, "the five off screen re-attached \(offScreen.count) times")
        #expect(offScreen.maxInFlight == 1, "\(offScreen.maxInFlight) off-screen resumes were out at once")
    }
}
