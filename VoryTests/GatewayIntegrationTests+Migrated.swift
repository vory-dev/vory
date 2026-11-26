import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The mock behind the E2E settings (HERMES_E2E_WIRE): its plain mode, Hermes's session authority, or a gateway
/// after its backends were migrated. The tests below that need one kind of gateway are skipped on the others.
enum E2EWire: String {
    case plain = "default", authority, migrated

    static var current: E2EWire? { ProcessInfo.processInfo.environment["HERMES_E2E_WIRE"].flatMap(E2EWire.init(rawValue:)) }
    /// The settings sign in with a user and password, not a token.
    static var password: Bool { let c = E2EConfig.load(); return (c?.token ?? "").isEmpty && c?.user != nil }
    /// The session token a migrated gateway refuses (HERMES_E2E_OLD_TOKEN).
    static var oldToken: String? { ProcessInfo.processInfo.environment["HERMES_E2E_OLD_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } }
}

extension GatewayIntegrationTests {
    static var onWire: Bool { configured && E2EWire.current != nil }
    static var migratedWire: Bool { onWire && E2EWire.current == .migrated }
    static var migratedTokenWire: Bool { migratedWire && !E2EWire.password && E2EWire.oldToken != nil }
    static var passwordWire: Bool { onWire && E2EWire.password }

    struct CompatRuntime { let runtime: GatewayRuntime; let store: ConnectionStore; let conn: GatewayConnection }

    /// A started runtime on the mock, signed in as the E2E settings say (a token, or a user and password), or with
    /// `token` in their place.
    @MainActor func compatRuntime(_ name: String, token: String? = nil) async throws -> CompatRuntime {
        let c = try #require(E2EConfig.load())
        let r = try await c.resolve()
        let mode: AuthMode = token == nil ? r.mode : .sessionToken
        let secrets = token.map { GatewaySecrets(sessionToken: $0) } ?? r.secrets
        let store = ConnectionStore()
        let conn = GatewayConnection(name: name, gateway: r.gateway, authMode: mode)
        try store.upsert(conn, secrets: secrets)
        let runtime = GatewayRuntime(connection: conn, store: store)
        await runtime.start()
        return CompatRuntime(runtime: runtime, store: store, conn: conn)
    }

    @MainActor func until(_ seconds: TimeInterval, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// `until`, for a wait on a turn: the mock's scripted turn asks for an approval, so each pass answers the chat's
    /// approval card as the two-device test does (`respond(card:result:)` with "once").
    @MainActor func untilAnswering(_ seconds: TimeInterval, _ chat: ChatSession, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() >= deadline { return false }
            if let card = chat.cards.first(where: { $0.method == "approval" }) { await chat.respond(card: card, result: ["choice": "once"]) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// A call to the mock's own test routes (/mock/... and /api/_mock/...), which take no sign-in.
    func mockCall(_ path: String, method: String = "GET") async throws -> (status: Int, body: Data) {
        let c = try #require(E2EConfig.load())
        let base = c.url.hasSuffix("/") ? String(c.url.dropLast()) : c.url
        var req = URLRequest(url: try #require(URL(string: base + path)))
        req.httpMethod = method
        if method == "POST" {
            req.httpBody = Data("{}".utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The last prompt.submit the mock's session authority admitted (GET /api/_mock/authority).
    func lastSubmit() async throws -> [String: JSONValue]? {
        let (_, data) = try await mockCall("/api/_mock/authority")
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        return v["submits"]?.arrayValue?.last?.objectValue
    }

    @MainActor func errors(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { if case .error(let t) = $0.kind { return t }; return nil }
    }

    @MainActor func replies(_ chat: ChatSession) -> Int {
        chat.items.filter { if case .assistant(let t, _, let streaming) = $0.kind { return !t.isEmpty && !streaming }; return false }.count
    }

    // MARK: 1 to 3: the model pick

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.onWire, "no HERMES_E2E_WIRE"))
    func aModelPickSticksOnAMigratedGateway() async throws {
        let e = try await compatRuntime("e2e model pick")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        let pick = "anthropic/claude-opus-4.6"
        try await chat.setModel(provider: nil, model: pick)
        #expect(await until(10) { chat.info?.model == pick }, "the chat's info doesn't show the pick")
        await e.runtime.stop()
    }

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.migratedWire, "no confirmation on this wire"))
    func anExpensiveModelPickAsksBeforeItApplies() async throws {
        let e = try await compatRuntime("e2e expensive pick")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        let pick = "mock-premium-model"
        try await chat.setModel(provider: nil, model: pick)
        let pending = try #require(chat.pendingModelConfirmation, "no confirmation asked for")
        #expect(pending.model == pick)
        #expect(!pending.message.isEmpty, "the confirmation has no words")
        // Left unconfirmed, it never applies.
        try? await Task.sleep(for: .seconds(2))
        #expect(chat.info?.model != pick, "the pick applied before the person confirmed it")
        try await chat.confirmModel()
        #expect(await until(10) { chat.info?.model == pick }, "the confirmed pick didn't apply")
        #expect(chat.pendingModelConfirmation == nil)
        await e.runtime.stop()
    }

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.migratedWire, "no deferred pick on this wire"))
    func aModelPickDuringATurnWaitsForTheNextTurn() async throws {
        let e = try await compatRuntime("e2e deferred pick")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        _ = await chat.send("long 15")
        #expect(await until(10) { chat.isRunning }, "the turn didn't start")
        try await chat.setModel(provider: nil, model: "anthropic/claude-haiku-4.5")
        #expect(chat.banner == "Model change applies at the next turn.")
        await e.runtime.stop()
    }

    // MARK: 4: YOLO

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.onWire, "no HERMES_E2E_WIRE"))
    func aYoloToggleSticksOnAMigratedGateway() async throws {
        let e = try await compatRuntime("e2e yolo")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        try await chat.setYolo(true)
        try await chat.setYolo(false)
        await e.runtime.stop()
    }

    // MARK: 5 and 6: PDFs and pictures

    /// The smallest file a PDF reader takes.
    static let tinyPDF = Data("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".utf8)
    /// A one-pixel PNG.
    static let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.onWire, "no HERMES_E2E_WIRE"))
    func aPDFAttachesOnAMigratedGateway() async throws {
        let e = try await compatRuntime("e2e pdf")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        chat.stageAttachment(data: Self.tinyPDF, name: "e2e.pdf", kind: .pdf)
        _ = await chat.send("read the file")
        #expect(await untilAnswering(20, chat) { !chat.isRunning && self.replies(chat) > 0 || !self.errors(chat).isEmpty })
        #expect(errors(chat).isEmpty, "error rows: \(errors(chat))")
        if E2EWire.current == .migrated {
            // The turn's own text carries the file's reference.
            let text = try await lastSubmit()?["text"]?.stringValue ?? ""
            #expect(text.contains("e2e.pdf"), "the turn's text has no reference to the file")
        }
        await e.runtime.stop()
    }

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.migratedWire, "pictures are queued by the gateway on this wire"))
    func aPictureReachesTheTurnOnAMigratedGateway() async throws {
        let e = try await compatRuntime("e2e picture")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        chat.stageAttachment(data: Self.tinyPNG, name: "e2e.png", kind: .image)
        _ = await chat.send("look at this")
        #expect(await untilAnswering(20, chat) { !chat.isRunning && self.replies(chat) > 0 || !self.errors(chat).isEmpty })
        let attachments = try await lastSubmit()?["attachments"]?.arrayValue ?? []
        #expect(attachments.count == 1, "the turn got \(attachments.count) attachment(s)")
        if let a = attachments.first?.objectValue {
            #expect(Set(a.keys) == ["path", "mime"], "keys \(a.keys.sorted())")
            #expect(a["mime"]?.stringValue == "image/png")
            #expect(a["path"]?.stringValue?.hasSuffix(".png") == true)
        }
        await e.runtime.stop()
    }

    // MARK: 7: a failed turn

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.onWire, "no HERMES_E2E_WIRE"))
    func aFailedTurnSaysWhyOnAMigratedGateway() async throws {
        let e = try await compatRuntime("e2e failed turn")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        _ = await chat.send("fail turn")
        #expect(await until(20) { !self.errors(chat).isEmpty }, "no error row for the failed turn")
        if E2EWire.current == .migrated {
            // The app's own words, never the gateway's code: this turn's error_surface code has no words of its own.
            #expect(errors(chat).contains("The turn failed."), "the row isn't the app's own: \(errors(chat))")
            #expect(!errors(chat).contains { $0.contains("provider_auth") }, "the bare code was shown: \(errors(chat))")
        } else {
            #expect(errors(chat).contains { !$0.isEmpty })
        }
        await e.runtime.stop()
    }

    // MARK: 8: the old session token

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.migratedTokenWire, "no token check on this wire"))
    func theOldSessionTokenNamesTheNewOne() async throws {
        let c = try #require(E2EConfig.load())
        let old = try #require(E2EWire.oldToken)
        let conn = GatewayConnection(name: "e2e old token", gateway: try GatewayURL.normalize(c.url), authMode: .sessionToken)
        let outcome = await ConnectionTester.run(connection: conn, secrets: GatewaySecrets(sessionToken: old), progress: { _ in })
        let failed = outcome.steps.compactMap { if case .failed(let t) = $0.status { return t }; return nil }
        #expect(!failed.isEmpty, "the old token was taken")
        #expect(failed.contains { $0.contains("webapp/session-token") }, "the words don't name the new token's file: \(failed)")
    }

    // MARK: 9: a restart waited out

    /// The socket's states, read every 100 ms while a test runs.
    @MainActor final class StateLog {
        private(set) var states: [SocketState] = []
        private var task: Task<Void, Never>?
        func start(_ runtime: GatewayRuntime) {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled { self?.states.append(runtime.socketState); try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
        func stop() { task?.cancel() }
    }

    /// Whether a socket state names a restart as a failure: failed, or an HTTP 503 or 403 named as the problem.
    static func readsAsFailure(_ s: SocketState) -> Bool {
        if case .failed = s { return true }
        if case .unreachable(let p, _) = s, case .http(let status) = p, status == 503 || status == 403 { return true }
        return false
    }

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.onWire, "no HERMES_E2E_WIRE"))
    func aDrainIsWaitedOut() async throws {
        let e = try await compatRuntime("e2e restart")
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        _ = try await runtime.newChat()
        #expect(await until(15) { runtime.socketState.isOpen }, "not open before the restart")
        let log = StateLog()
        log.start(runtime)
        _ = try await mockCall("/mock/fault?mode=draining&count=5")
        try? await Task.sleep(for: .seconds(1))
        let api = runtime.api
        let read = Task { () -> Bool in
            do { let _: JSONValue = try await api.get("/api/status", authenticated: false); return true } catch { return false }
        }
        try? await Task.sleep(for: .seconds(4))
        _ = try await mockCall("/mock/fault?mode=starting&count=5")
        #expect(await read.value, "a read started inside the restart failed")
        #expect(await until(40) { runtime.socketState.isOpen }, "the socket isn't open after the restart")
        log.stop()
        let failures = log.states.filter(Self.readsAsFailure)
        #expect(failures.isEmpty, "the restart read as a failure: \(failures.prefix(3))")
        await e.runtime.stop()
    }

    // MARK: 10: a refused refresh

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.passwordWire, "no password sign-in on this wire"))
    func aRefusedRefreshSaysWhy() async throws {
        let e = try await compatRuntime("e2e refused refresh")
        defer { e.store.delete(id: e.conn.id) }
        _ = try await e.runtime.newChat()
        // No remembered sign-in, so the refused refresh stands: the runtime can't sign in again by itself.
        #expect(e.runtime.signInAgain == nil, "a sign-in is remembered: the refused refresh would be mended")
        _ = try await mockCall("/api/_mock/expire-sessions", method: "POST")
        await e.runtime.reconnectNow()
        #expect(await until(20) { e.runtime.refreshRefused }, "the refused refresh wasn't noted")
        var why = ""
        if case .authRejected(let w) = e.runtime.socketState { why = w }
        let words = ConnectProblem.refusedWords(why: why, authMode: e.conn.authMode, refreshRefused: e.runtime.refreshRefused).lowercased()
        #expect(words.contains("sign in again"), "the words don't say to sign in again: \(words)")
        #expect(words.contains("hermes update"), "the words don't say why: \(words)")
        await e.runtime.stop()
    }

    // MARK: 11: a bot the gateway doesn't serve

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.migratedTokenWire, "no unserved bot on this wire"))
    func anUnservedBotIsSaidPlainly() async throws {
        let e = try await compatRuntime("e2e unserved bot")
        defer { e.store.delete(id: e.conn.id) }
        _ = try await e.runtime.newChat()
        do {
            _ = try await e.runtime.rpc("session.list", [:], profile: "writer")
            Issue.record("a call naming the unserved bot was answered")
        } catch {
            let words = error.localizedDescription
            #expect(!words.contains("profile_mismatch"), "the bare code was shown: \(words)")
            #expect(words.contains("doesn't run that bot"), "not the plain words: \(words)")
        }
        await e.runtime.stop()
    }

    // MARK: 12 and 13: the authority's two events

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.onWire, "no HERMES_E2E_WIRE"))
    func aReplayGapReattaches() async throws {
        let e = try await compatRuntime("e2e replay gap")
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        _ = await chat.send("hello")
        #expect(await untilAnswering(20, chat) { !chat.isRunning && self.replies(chat) > 0 }, "no first reply")
        let before = replies(chat)
        let stored = chat.storedID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? chat.storedID
        _ = try await mockCall("/mock/replay-gap?session=\(stored)")
        try? await Task.sleep(for: .seconds(1))
        _ = try await mockCall("/mock/start-turn?session=\(stored)&prompt=after%20the%20gap")
        #expect(await untilAnswering(30, chat) { self.replies(chat) > before }, "the turn after the gap wasn't shown")
        await e.runtime.stop()
    }

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.migratedWire, "no session.updated on this wire"))
    func aRenameArrivesBySessionUpdated() async throws {
        let a = try await compatRuntime("e2e rename a")
        defer { a.store.delete(id: a.conn.id) }
        let b = try await compatRuntime("e2e rename b")
        defer { b.store.delete(id: b.conn.id) }
        let chatA = try await a.runtime.newChat()
        _ = await chatA.send("hello")
        #expect(await untilAnswering(20, chatA) { !chatA.isRunning && self.replies(chatA) > 0 })
        let chatB = try await b.runtime.openChat(storedID: chatA.storedID, title: nil, waitForResume: true)
        let newTitle = "e2e renamed \(Int(Date().timeIntervalSince1970))"
        await chatB.rename(newTitle)
        #expect(await until(15) { chatA.title == newTitle }, "the first client shows '\(chatA.title)'")
        await a.runtime.stop(); await b.runtime.stop()
    }

    // MARK: 15: a restart, then the old token refused

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.migratedTokenWire, "no refused token on this wire"))
    func aRestartEndsAtARefusedSignIn() async throws {
        let old = try #require(E2EWire.oldToken)
        // A restart's two halves, as a backend migration's own: draining, then the new process starting. The
        // runtime holding the old token comes up inside it, and the token is refused once the gateway is ready.
        _ = try await mockCall("/mock/fault?mode=draining&count=5")
        let e = try await compatRuntime("e2e restart then refusal", token: old)
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        let log = StateLog()
        log.start(runtime)
        try? await Task.sleep(for: .seconds(5))
        _ = try await mockCall("/mock/fault?mode=starting&count=5")
        #expect(await until(40) { if case .authRejected = runtime.socketState { return true }; return false }, "the old token's refusal wasn't shown")
        log.stop()
        let failures = log.states.filter(Self.readsAsFailure)
        #expect(failures.isEmpty, "the restart read as a failure: \(failures.prefix(3))")
        var why = ""
        if case .authRejected(let w) = e.runtime.socketState { why = w }
        let words = ConnectProblem.refusedWords(why: why, authMode: .sessionToken, refreshRefused: e.runtime.refreshRefused)
        #expect(words.contains("webapp/session-token"), "the refusal's words don't name the new token's file: \(words)")
        await e.runtime.stop()
    }
}
