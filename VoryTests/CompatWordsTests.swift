import Foundation
import Testing
@testable import VoryCore

/// Words for a gateway after Hermes's update: a failed turn's, the failed socket's hint, and a bot the gateway
/// doesn't serve.
@Suite struct CompatWordsTests {
    /// A turn's end as message.complete carries it. On Hermes's session authority a failed turn has status "error",
    /// an empty text and no error string: an error_surface always, a failure_reason only for some turns, each a code.
    struct TurnEnd: Sendable, CustomTestStringConvertible {
        var name: String
        var payload: JSONValue
        var words: String?
        var testDescription: String { name }
    }

    static func failed(reason: String? = nil, surface: String? = nil) -> JSONValue {
        var p: [String: JSONValue] = ["status": .string("error"), "text": .string("")]
        if let reason { p["failure_reason"] = .string(reason) }
        if let surface { p["error_surface"] = .object(["layer": .string("provider"), "code": .string(surface), "retryable": .bool(true)]) }
        return .object(p)
    }

    static let turnEnds: [TurnEnd] = [
        .init(name: "an error string", payload: .object(["status": .string("error"), "error": .string("Provider timed out")]),
              words: "Provider timed out"),
        .init(name: "a failure reason before its surface", payload: failed(reason: "gateway_connection", surface: "auth"),
              words: "Couldn't reach your gateway."),
        .init(name: "a busy session", payload: failed(reason: "session_busy"),
              words: "Your bot is busy with another turn. Try again in a moment."),
        .init(name: "a blocked request", payload: failed(reason: "content_policy_blocked"), words: "The model declined this request."),
        .init(name: "an error surface's code only", payload: failed(surface: "auth"), words: "The model provider rejected the API key."),
        .init(name: "a local model server that's down", payload: failed(surface: "local_runtime_unavailable"),
              words: "The local model server isn't running."),
        .init(name: "a request too large", payload: failed(surface: "payload_too_large"), words: "This request is too large for the model."),
        .init(name: "a model the provider doesn't offer", payload: failed(surface: "model_not_found"), words: "The model provider doesn't offer this model."),
        .init(name: "an unknown reason falls to its surface", payload: failed(reason: "billing_wall_7", surface: "rate_limit"),
              words: "The model provider is limiting requests. Try again in a moment."),
        .init(name: "unknown codes", payload: failed(reason: "billing_wall_7", surface: "provider_error"), words: "The turn failed."),
        .init(name: "status error with neither", payload: .object(["status": .string("error")]), words: "The turn failed."),
        .init(name: "a failed turn with words of its own", payload: .object(["text": .string("Error: x"), "status": .string("error")]), words: nil),
        .init(name: "a completed turn", payload: .object(["status": .string("complete"), "text": .string("Done.")]), words: nil),
    ]

    @Test(arguments: turnEnds)
    func aFailedTurnSaysWhy(_ t: TurnEnd) {
        let words = ChatSession.turnFailure(t.payload)
        #expect(words == t.words)
        // A code is never shown as it is.
        for code in [t.payload["failure_reason"]?.stringValue, t.payload["error_surface"]?["code"]?.stringValue].compactMap({ $0 }) {
            #expect(!(words ?? "").contains(code), "the code \(code) was shown: \(words ?? "")")
        }
    }

    /// The turn-finished notices a chat gives, with their errors.
    @MainActor final class TurnNotes: CardNotifying {
        var finished: [String?] = []
        func cardArrived(_ card: PendingCard, chat: ChatSession) {}
        func turnFinished(chat: ChatSession, error: String?) { finished.append(error) }
    }

    /// A failed turn that left its own words (a compute host's, with no error key) shows as it always has: its words as
    /// the reply, no second row, and the one turn-finished notice, with no error.
    @MainActor @Test func aFailedTurnWithItsOwnWordsShowsAsBefore() throws {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        let notes = TurnNotes()
        rt.cardNotifier = notes
        let chat = ChatSession(runtime: rt, storedID: nil, title: nil)
        rt.registry.add(chat)
        chat.handle(event: GatewayEvent(type: "message.start", sessionID: "s1", payload: .object([:]), seq: nil))
        chat.handle(event: GatewayEvent(type: "message.complete", sessionID: "s1",
                                        payload: .object(["text": .string("Error: x"), "status": .string("error")]), seq: nil))
        let errors = chat.items.compactMap { item -> String? in if case .error(let t) = item.kind { return t }; return nil }
        let replies = chat.items.compactMap { item -> String? in if case .assistant(let t, _, _) = item.kind { return t }; return nil }
        #expect(errors.isEmpty, "a second row: \(errors)")
        #expect(replies == ["Error: x"], "the turn's own words: \(replies)")
        #expect(notes.finished.count == 1, "\(notes.finished.count) turn-finished notices")
        #expect(notes.finished.first == .some(nil), "the notice said the turn failed: \(String(describing: notes.finished.first))")
    }

    /// A migrated gateway reads webapp.public_url, which its update copies from dashboard.public_url when unset.
    @Test func theSocketHintNamesBothPublicURLSettings() {
        #expect(ConnectionTester.publicURLHint.contains("dashboard.public_url"))
        #expect(ConnectionTester.publicURLHint.contains("webapp.public_url"), "the updated gateway's setting isn't named")
    }

    /// A call naming a bot this gateway doesn't serve is refused profile_mismatch before any handler.
    @Test func aBotTheGatewayDoesntServeIsSaidPlainly() {
        let words = "This gateway doesn't run that bot. Its own bots still work here."
        #expect(RPCError(code: 4001, message: "profile_mismatch", data: .object(["reason": .string("profile_mismatch")])).errorDescription == words)
        #expect(RPCError(code: 4001, message: "profile_mismatch").errorDescription == words, "the reason with no data wasn't read")
        #expect(RPCError(code: 4001, message: "session not found").errorDescription == "session not found", "another refusal lost its words")
    }
}
