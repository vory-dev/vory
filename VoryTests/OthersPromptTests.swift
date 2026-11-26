import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// On Hermes's session authority, a prompt another client sent reaches this chat only as an entry of `session.info`'s
/// `pending` list: the admission's public text and the input id its sender named it by, listed while it is queued and
/// again once its claim started it. The claim's `message.start` carries nothing of a person's prompt. Once the entry
/// reads `started`, the prompt shows here as an ordinary user row: once per admission, never this chat's own, in front
/// of the reply its claim began. A transcript fetched again puts the stored message in its place. On a socket without
/// the authority nothing changes.
@MainActor @Suite struct OthersPromptTests {
    private func runtime(authority: Bool) throws -> GatewayRuntime {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        var payload: [String: JSONValue] = ["change_events": true, "heartbeat": true]
        if authority { payload["session_authority"] = true }
        rt.handle(batch: [GatewayEvent(type: "gateway.ready", sessionID: "", payload: .object(payload))])
        return rt
    }

    /// The calls a chat made, by method, with their params.
    final class Calls {
        var sent: [(method: String, params: [String: JSONValue])] = []
        func last(_ method: String) -> [String: JSONValue]? { sent.last { $0.method == method }?.params }
    }

    /// A chat attached as `rt-a`, its calls recorded; a prompt is admitted, and a resume answers with the stored turn, or
    /// with `resume` when one is given.
    private func chat(authority: Bool = true, resume: JSONValue? = nil) async throws -> (ChatSession, Calls) {
        let calls = Calls()
        let c = ChatSession(runtime: try runtime(authority: authority), storedID: nil, title: nil)
        c.gatewayStandIn = { method, params in
            calls.sent.append((method, params))
            switch method {
            case "session.create":
                return ["session_id": "rt-a", "stored_session_id": "st-a", "execution_generation": 3, "revision": 4,
                        "subscription_id": "sub-1", "messages": [], "running": false, "info": ["title": "Logs"]]
            case "prompt.submit":
                return ["status": "queued"]
            case "session.resume":
                if let resume { return resume }
                return ["session_id": "rt-a", "stored_session_id": "st-a", "running": false, "execution_generation": 4, "revision": 5,
                        "subscription_id": "sub-2", "messages": [["role": "user", "text": "Clear the old logs", "row_id": 5],
                                                                 ["role": "assistant", "text": "Done.", "row_id": 6]]]
            default:
                return .object([:])
            }
        }
        try await c.create()
        return (c, calls)
    }

    /// An entry of the authority's pending list, as `_pending_receipt` makes it.
    private func entry(_ admission: String, input: String, text: String = "Clear the old logs", status: String,
                       steering: Bool = false) -> JSONValue {
        ["admission_id": .string(admission), "ref": ["session_id": "st-a"], "sequence": 1, "status": .string(status),
         "outcome": .null, "authority_epoch": 1, "execution_generation": 3, "input_id": .string(input),
         "text": .string(text), "controls": [], "steering": .bool(steering)]
    }

    private func info(_ c: ChatSession, pending: [JSONValue], running: Bool = true) {
        c.handle(event: GatewayEvent(type: "session.info", sessionID: "rt-a", payload: [
            "stored_session_id": "st-a", "pending": .array(pending), "running": .bool(running), "authority_epoch": 1,
            "desktop_protocol": "hermes-gateway-v1", "execution_generation": 3, "revision": 4]))
    }

    private func claimStarts(_ c: ChatSession) {
        c.handle(event: GatewayEvent(type: "message.start", sessionID: "rt-a", payload: [:]))
    }

    private func userTexts(_ c: ChatSession) -> [String] {
        c.items.compactMap { if case .user(let t, _) = $0.kind { return t }; return nil }
    }

    @Test func anotherClientsStartedPromptShowsAsAUserRow() async throws {
        let (c, _) = try await chat()
        claimStarts(c)
        info(c, pending: [entry("adm-1", input: "other-1", status: "started")])
        #expect(userTexts(c) == ["Clear the old logs"])
        // An ordinary user row, nothing more, in front of the reply its claim began.
        let i = try #require(c.items.firstIndex { if case .user = $0.kind { return true }; return false })
        if case .user(_, let attachments) = c.items[i].kind { #expect(attachments.isEmpty) }
        let next = try #require(c.items.indices.contains(i + 1) ? c.items[i + 1] : nil)
        if case .assistant(_, _, let streaming) = next.kind { #expect(streaming) } else { Issue.record("the row after the prompt isn't the reply") }
    }

    @Test func anAdmissionShowsOnceHoweverOftenItIsListed() async throws {
        let (c, _) = try await chat()
        claimStarts(c)
        for _ in 0..<3 { info(c, pending: [entry("adm-1", input: "other-1", status: "started")]) }
        #expect(userTexts(c) == ["Clear the old logs"])
    }

    @Test func thisChatsOwnPromptIsNeverShownTwice() async throws {
        let (c, calls) = try await chat()
        _ = await c.send("Clear the old logs")
        let own = try #require(calls.last("prompt.submit")?["input_id"]?.stringValue)
        claimStarts(c)
        info(c, pending: [entry("adm-1", input: own, status: "started")])
        #expect(userTexts(c) == ["Clear the old logs"])
    }

    @Test func aQueuedEntryWaitsForItsClaim() async throws {
        let (c, _) = try await chat()
        info(c, pending: [entry("adm-1", input: "other-1", status: "queued")], running: false)
        #expect(userTexts(c).isEmpty)
        claimStarts(c)
        info(c, pending: [entry("adm-1", input: "other-1", status: "started")])
        #expect(userTexts(c) == ["Clear the old logs"])
    }

    @Test func theTurnSettlingLeavesOneRow() async throws {
        let (c, _) = try await chat()
        claimStarts(c)
        info(c, pending: [entry("adm-1", input: "other-1", status: "started")])
        c.handle(event: GatewayEvent(type: "message.complete", sessionID: "rt-a", payload: ["text": "Done.", "status": "complete"]))
        info(c, pending: [], running: false)
        #expect(userTexts(c) == ["Clear the old logs"])
    }

    @Test func aTranscriptFetchedAgainTakesItsPlace() async throws {
        let (c, _) = try await chat()
        claimStarts(c)
        info(c, pending: [entry("adm-1", input: "other-1", status: "started")])
        #expect(userTexts(c) == ["Clear the old logs"])
        try await c.resume()
        #expect(userTexts(c) == ["Clear the old logs"])
        // A fetched row that says the same words as a shown one keeps that row's id, so the stored prompt may carry the
        // pending row's id: one row is what this test asks, and the userTexts lines hold it.
        // Listed again afterwards, the admission is still the one shown.
        info(c, pending: [entry("adm-1", input: "other-1", status: "started")], running: false)
        #expect(userTexts(c) == ["Clear the old logs"])
    }

    @Test func aSteeringEntryIsNotShown() async throws {
        let (c, _) = try await chat()
        claimStarts(c)
        // A queued admission in transfer to the running turn reads started and steering: a steer, not a turn's prompt.
        info(c, pending: [entry("adm-2", input: "other-2", text: "And the tmp folder too", status: "started", steering: true)])
        #expect(userTexts(c).isEmpty)
    }

    @Test func aPromptAlreadyShownForTheTurnIsNotShownTwice() async throws {
        // Attached mid-turn: the resume shows the running turn's prompt as its inflight one.
        let midTurn: JSONValue = ["session_id": "rt-a", "stored_session_id": "st-a", "running": true, "execution_generation": 4,
                                  "revision": 5, "subscription_id": "sub-2", "messages": [],
                                  "inflight": ["user": "Clear the old logs", "assistant": "", "streaming": true]]
        let (c, _) = try await chat(resume: midTurn)
        try await c.resume()
        #expect(userTexts(c) == ["Clear the old logs"])
        info(c, pending: [entry("adm-1", input: "other-1", status: "started")])
        #expect(userTexts(c) == ["Clear the old logs"])
    }

    @Test func aSocketWithoutTheAuthorityIsUnchanged() async throws {
        let (c, _) = try await chat(authority: false)
        claimStarts(c)
        info(c, pending: [entry("adm-1", input: "other-1", status: "started")])
        #expect(userTexts(c).isEmpty)
    }
}
