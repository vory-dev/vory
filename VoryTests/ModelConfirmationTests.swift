import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A model pick the gateway asks the person to confirm belongs to its chat as it was: another pick, the chat's close
/// and a reconnect each drop it, and only the person's yes sends it.
@MainActor @Suite struct ModelConfirmationTests {
    /// A chat on a runtime that never connects: its calls fail at once, so only what happens before them is read.
    func offlineChat() throws -> (ChatSession, ConnectionStore, GatewayConnection) {
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "confirm", gateway: try GatewayURL.normalize("http://127.0.0.1:9"), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: "t"))
        let runtime = GatewayRuntime(connection: conn, store: store)
        return (ChatSession(runtime: runtime, storedID: "s", title: "t"), store, conn)
    }

    func offer(_ chat: ChatSession) {
        chat.offerModelConfirmation(.init(model: "premium", provider: nil, message: "It costs more."), provider: nil, model: "premium", token: "tok")
    }

    @Test func anotherPickDropsTheWaitingOne() async throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        #expect(chat.pendingModelConfirmation != nil)
        try? await chat.setModel(provider: nil, model: "other")
        #expect(chat.pendingModelConfirmation == nil)
    }

    @Test func theChatsCloseDropsIt() async throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        await chat.close()
        #expect(chat.pendingModelConfirmation == nil)
    }

    @Test func aReconnectDropsIt() throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        chat.noteReconnected()
        #expect(chat.pendingModelConfirmation == nil)
    }

    @Test func theAlertsYesTakesTheOfferItShowed() throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let shown = try #require(chat.pendingModelConfirmation)
        #expect(chat.acceptModelConfirmation(shown), "the waiting offer wasn't taken")
        #expect(chat.pendingModelConfirmation == nil, "the alert would show again")
    }

    @Test func aYesAfterACancelSendsNothing() throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let shown = try #require(chat.pendingModelConfirmation)
        chat.cancelModelConfirmation()
        #expect(!chat.acceptModelConfirmation(shown))
    }

    @Test func aYesAfterAReconnectSendsNothing() throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let shown = try #require(chat.pendingModelConfirmation)
        chat.noteReconnected()
        #expect(!chat.acceptModelConfirmation(shown))
    }

    @Test func aYesForAnOlderOfferSendsNothing() throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let older = try #require(chat.pendingModelConfirmation)
        offer(chat)
        #expect(!chat.acceptModelConfirmation(older), "an answer reached an offer it wasn't shown for")
        #expect(chat.pendingModelConfirmation != nil, "the newer offer was dropped")
    }

    @Test func cancelDropsIt() throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        chat.cancelModelConfirmation()
        #expect(chat.pendingModelConfirmation == nil)
    }

    @Test func aRefusalsReasonIsItsDataReasonElseItsMessage() {
        #expect(RPCError(code: 4001, message: "words", data: .object(["reason": .string("use_session_mutation_model")])).reason == "use_session_mutation_model")
        #expect(RPCError(code: 4001, message: "use_session_mutation_model").reason == "use_session_mutation_model")
    }

    // What waits on the answer (a new chat's first message, the "/model" line) goes on when the question ends.

    @Test func aWaitForTheAnswerEndsUnusedOnCancel() async throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let shown = try #require(chat.pendingModelConfirmation)
        let wait = Task { await chat.modelConfirmationAnswer(shown) }
        await Task.yield()
        chat.cancelModelConfirmation()
        #expect(await wait.value == false)
    }

    @Test func aWaitForTheAnswerEndsUnusedOnAReconnect() async throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let shown = try #require(chat.pendingModelConfirmation)
        let wait = Task { await chat.modelConfirmationAnswer(shown) }
        await Task.yield()
        chat.noteReconnected()
        #expect(await wait.value == false)
    }

    @Test func aNewerOfferEndsTheWaitOnTheOlder() async throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let older = try #require(chat.pendingModelConfirmation)
        let wait = Task { await chat.modelConfirmationAnswer(older) }
        await Task.yield()
        offer(chat)
        #expect(await wait.value == false)
        #expect(chat.pendingModelConfirmation != nil, "the newer offer was dropped")
    }

    @Test func aWaitsOwnCancelEndsItAndLeavesTheQuestion() async throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let shown = try #require(chat.pendingModelConfirmation)
        let wait = Task { await chat.modelConfirmationAnswer(shown) }
        await Task.yield()
        wait.cancel()
        #expect(await wait.value == false)
        #expect(chat.pendingModelConfirmation?.id == shown.id, "the question went with the wait")
    }

    @Test func aYesThatCantBeSentReadsAsUnused() async throws {
        let (chat, store, conn) = try offlineChat(); defer { store.delete(id: conn.id) }
        offer(chat)
        let shown = try #require(chat.pendingModelConfirmation)
        let wait = Task { await chat.modelConfirmationAnswer(shown) }
        await Task.yield()
        #expect(chat.acceptModelConfirmation(shown))
        #expect(await wait.value == false, "a yes the gateway never got read as applied")
        #expect(chat.banner != nil, "the refusal wasn't said")
    }
}

/// Which of a chat's views asks its question: the last sheet up, else the chat's own page; nothing while a sheet that
/// doesn't ask is up.
@MainActor @Suite struct ModelConfirmationHostsTests {
    func chats() throws -> (ChatSession, ChatSession, ConnectionStore, GatewayConnection) {
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "hosts", gateway: try GatewayURL.normalize("http://127.0.0.1:9"), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: "t"))
        let runtime = GatewayRuntime(connection: conn, store: store)
        return (ChatSession(runtime: runtime, storedID: "a", title: "a"), ChatSession(runtime: runtime, storedID: "b", title: "b"), store, conn)
    }

    @Test func aSheetOverTheChatAsksThenThePageAgain() throws {
        let (a, _, store, conn) = try chats(); defer { store.delete(id: conn.id) }
        let hosts = ModelConfirmationHosts(), page = UUID(), card = UUID(), list = UUID()
        hosts.appeared(page, chat: a, in: .page)
        #expect(hosts.asks(page, for: a))
        hosts.appeared(card, chat: a, in: .sheet)
        hosts.appeared(list, chat: a, in: .sheet)
        #expect(hosts.asks(list, for: a) && !hosts.asks(card, for: a) && !hosts.asks(page, for: a), "a covered view asked")
        hosts.disappeared(list)
        #expect(hosts.asks(card, for: a), "the card under the list didn't ask once it had gone")
        hosts.disappeared(card)
        #expect(hosts.asks(page, for: a))
    }

    @Test func aSheetThatDoesntAskHoldsEveryQuestion() throws {
        let (a, _, store, conn) = try chats(); defer { store.delete(id: conn.id) }
        let hosts = ModelConfirmationHosts(), compose = UUID(), page = UUID()
        hosts.covered(compose)
        hosts.appeared(page, chat: a, in: .page)
        #expect(!hosts.asks(page, for: a), "asked under the compose sheet as it closed")
        hosts.disappeared(compose)
        #expect(hosts.asks(page, for: a))
    }

    @Test func aCoveredSheetOverThePageHoldsItsQuestionUntilItGoes() throws {
        let (a, _, store, conn) = try chats(); defer { store.delete(id: conn.id) }
        let hosts = ModelConfirmationHosts(), page = UUID(), context = UUID()
        hosts.appeared(page, chat: a, in: .page)
        #expect(hosts.asks(page, for: a))
        hosts.covered(context)
        #expect(!hosts.asks(page, for: a), "asked under a sheet that covers the page")
        hosts.disappeared(context)
        #expect(hosts.asks(page, for: a), "the page didn't ask once the sheet had gone")
    }

    @Test func aPageBesideCoversNothingButASheetOverItDoes() throws {
        let (a, b, store, conn) = try chats(); defer { store.delete(id: conn.id) }
        let hosts = ModelConfirmationHosts(), pageA = UUID(), pageB = UUID(), cardB = UUID()
        hosts.appeared(pageA, chat: a, in: .page)
        hosts.appeared(pageB, chat: b, in: .page)
        #expect(hosts.asks(pageA, for: a) && hosts.asks(pageB, for: b))
        hosts.appeared(cardB, chat: b, in: .sheet)
        #expect(!hosts.asks(pageA, for: a), "asked under another chat's sheet")
        #expect(hosts.asks(cardB, for: b))
    }

    @Test func twoPagesOfOneChatAskOnce() throws {
        let (a, _, store, conn) = try chats(); defer { store.delete(id: conn.id) }
        let hosts = ModelConfirmationHosts(), left = UUID(), right = UUID()
        hosts.appeared(left, chat: a, in: .page)
        hosts.appeared(right, chat: a, in: .page)
        #expect(hosts.asks(right, for: a) != hosts.asks(left, for: a), "both pages asked, or neither")
    }
}
