import XCTest

/// A model pick the gateway asks the person to confirm, asked where the pick was made: over the bot card for its Model
/// row, over the model list when the list made the pick (on the card or on the chat), and on a new chat before its
/// first message goes. Use applies it, Cancel keeps the model, and the question passes the accessibility audit while
/// it's up.
///
/// Against the mock with `--migrated`, started with MOCK_CONFIRM_MODELS=mock-premium-model,nous/hermes-4-70b: a model the
/// mock lists, so the gateway asks about it; the mock's own read-back (`/api/_mock/authority`) says what was applied
/// and when the first message went. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set; HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class ModelConfirmationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var gatewayURL = ""

    private let asked = "nous/hermes-4-70b"
    private var askedRow: String { "models.row.nous::\(asked)" }

    /// The issues with no element in the audit just before the question shows, by kind (their short description).
    private var unplacedBefore: [String: Int] = [:]

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String) {
        gatewayURL = url
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func labelled(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        guard let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty else { return }
        let d = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
    }

    // MARK: The mock's read-back

    /// Every session.mutate applied and every prompt.submit admitted, as the mock recorded them.
    private func authority() -> [String: Any] {
        guard let u = URL(string: gatewayURL + "/api/_mock/authority") else { return [:] }
        let answer = Answer()
        let done = expectation(description: "authority")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            answer.json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return answer.json ?? [:]
    }

    /// The mock's answer, handed from URLSession's queue to the test (the expectation's wait orders them).
    private final class Answer: @unchecked Sendable { var json: [String: Any]? }

    /// The picks of the asked-about model applied since `t` (a deferred one isn't applied), on `session` if named.
    private func applied(since t: Double, session: String? = nil) -> [[String: Any]] {
        (authority()["mutations"] as? [[String: Any]] ?? []).filter {
            $0["operation"] as? String == "model" && $0["model"] as? String == asked && $0["status"] as? String != "deferred"
                && ($0["at"] as? Double ?? 0) >= t && (session == nil || $0["session_id"] as? String == session)
        }
    }

    /// The first message with these words, once the mock has it.
    private func submit(_ words: String) -> [String: Any]? {
        (authority()["submits"] as? [[String: Any]] ?? []).first { $0["text"] as? String == words }
    }

    /// The mock's reply to a first message stops on an approval (its disk cleanup) until it's answered. Deny answers it,
    /// and the mock then ends the turn with a line of its own. False, with a plain failure, when no card comes.
    private func denyTheReplysApproval() -> Bool {
        let deny = app.buttons.matching(NSPredicate(format: "label == 'Deny'")).firstMatch
        guard deny.waitForExistence(timeout: 30) else { XCTFail("no approval card to answer"); return false }
        deny.tap()
        return true
    }

    /// Waits for the chat's turn to end: the reply pill reads its resting words again. The app sets the pill's value from
    /// the chat's own running state ("Sends after this reply" while a turn runs, "Reply or hold to talk" after), so a
    /// test that ends here never leaves the app ended mid-reply for the next test's launch.
    private func waitForTheReplyToFinish(timeout: TimeInterval = 60) {
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Reply or hold to talk"), object: any("composer.pill"))
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: timeout), .completed, "the reply didn't finish in \(Int(timeout)) s")
    }

    private func eventually<T>(_ seconds: Double, _ read: () -> T?) -> T? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let v = read() { return v }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < end
        return nil
    }

    // MARK: Getting there

    /// A fresh chat, its composer up.
    private func openChat() {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        // The reply bar rests as its pill; the text field and the model chip are there once the pill is tapped.
        let pill = any("composer.pill")
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "no reply pill in the new chat")
        pill.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 30))
    }

    /// The bot card from the chat's title pill, scrolled to its Model row.
    private func openCardsModelRow() -> XCUIElement {
        let pill = app.buttons["chat.titlePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "no title pill")
        pill.tap()
        XCTAssertTrue(any("profile.header").waitForExistence(timeout: 10), "the card's header did not show")
        let row = any("profile.model")
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Model row on the card")
        return row
    }

    /// "All Models" from an open model menu, then the asked-about model's row in the list.
    private func openListAtTheAskedModel() -> XCUIElement {
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'models.all' OR label BEGINSWITH 'All Models'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), "no All Models in the model menu")
        all.tap()
        XCTAssertTrue(any("models.sheet").waitForExistence(timeout: 15), "the model list did not open")
        let field = app.searchFields.firstMatch
        if !field.exists { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field")
        field.tap()
        field.typeText("hermes-4-70b")
        let row = any(askedRow)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(asked)")
        return row
    }

    /// The gateway's question, its title the model.
    private func question() -> XCUIElement { app.alerts[asked].firstMatch }

    /// Waits for the question and reads it: the model as its title, the gateway's words, Use and Cancel.
    private func expectQuestion(_ over: String) -> XCUIElement {
        let q = question()
        XCTAssertTrue(q.waitForExistence(timeout: 15), "the gateway's question didn't show \(over)")
        XCTAssertTrue(q.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "costs much more")).firstMatch.exists,
                      "the question doesn't carry the gateway's words")
        XCTAssertTrue(q.buttons["Use \(asked)"].exists && q.buttons["Cancel"].exists, "the question's buttons aren't Use and Cancel")
        return q
    }

    /// Counts by kind, for the log.
    private func counts(_ c: [String: Int]) -> String {
        c.isEmpty ? "none" : c.sorted { $0.key < $1.key }.map { "'\($0.key)' \($0.value)" }.joined(separator: ", ")
    }

    /// The audit of the same screen just before the question shows. Its issues are the screen's own: printed
    /// (MODEL-CONFIRM-AUDIT before) and not judged here. Those with no element are counted by kind, to set against the
    /// audit with the question up.
    private func auditBefore(_ when: String) throws {
        var before: [String: Int] = [:]
        try app.performAccessibilityAudit { issue in
            if let el = issue.element {
                print("MODEL-CONFIRM-AUDIT \(when) before '\(issue.compactDescription)' label '\(el.label)'")
            } else {
                before[issue.compactDescription, default: 0] += 1
                print("MODEL-CONFIRM-AUDIT \(when) unplaced before '\(issue.compactDescription)'")
            }
            return true
        }
        unplacedBefore = before
        print("MODEL-CONFIRM-AUDIT \(when) unplaced before by kind: \(counts(before))")
    }

    /// The audit with the question up. An issue on the question's own elements fails; one on the screen under it is
    /// printed (MODEL-CONFIRM-AUDIT under), since that screen's own audit covers it. The question is iOS's own alert:
    /// its title and message don't follow Dynamic Type all the way, and its container reads as unlabeled text. Those two,
    /// on the alert's own elements only, are the stock alert's, printed (old, stock alert) and not judged here.
    /// An issue with no element can't be placed: it is printed (unplaced after) and not judged. Counted by kind against
    /// the audit just before, the ones the question brings are printed: of the stock alert's two kinds (Dynamic Type and
    /// unlabeled text) as "unplaced extra (stock alert)", of any other kind as "unplaced other".
    private func audit(_ when: String, _ q: XCUIElement) throws {
        let own = Set(([q] + q.descendants(matching: .any).allElementsBoundByIndex).map { "\($0.elementType.rawValue)|\($0.label)|\($0.frame)" })
        var after: [String: Int] = [:]
        var stockKinds: Set<String> = ["Potentially inaccessible text"]
        try app.performAccessibilityAudit { issue in
            guard let el = issue.element else {
                after[issue.compactDescription, default: 0] += 1
                if issue.auditType == .dynamicType { stockKinds.insert(issue.compactDescription) }
                print("MODEL-CONFIRM-AUDIT \(when) unplaced after '\(issue.compactDescription)'")
                return true
            }
            let inAlert = own.contains("\(el.elementType.rawValue)|\(el.label)|\(el.frame)")
            let stock = inAlert && (issue.auditType == .dynamicType
                || (issue.compactDescription == "Potentially inaccessible text" && el.label.isEmpty))
            let kind = stock ? "old (stock alert)" : inAlert ? "question" : "under"
            print("MODEL-CONFIRM-AUDIT \(when) \(kind) '\(issue.compactDescription)' label '\(el.label)'")
            return !inAlert || stock
        }
        print("MODEL-CONFIRM-AUDIT \(when) unplaced after by kind: \(counts(after))")
        for (kind, n) in after.sorted(by: { $0.key < $1.key }) {
            let extra = n - (unplacedBefore[kind] ?? 0)
            guard extra > 0 else { continue }
            print("MODEL-CONFIRM-AUDIT \(when) unplaced \(stockKinds.contains(kind) ? "extra (stock alert)" : "other") '\(kind)' \(extra)")
        }
    }

    /// The compose sheet: the default bot, the asked-about model from its chip, and a first message. On the iPhone it is
    /// the New Chat circle by the tab bar, pressed and held (a tap starts a chat at once). The sheet's own field and Send
    /// are newchat.text and newchat.send, and its field never rests as the reply pill.
    private func startComposedChat(_ words: String) {
        let compose = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: compose)], timeout: 60)
        compose.press(forDuration: 1.0)
        let to = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Bot name'")).firstMatch
        XCTAssertTrue(to.waitForExistence(timeout: 10), "no To: field")
        to.tap()
        to.typeText("default")
        let bot = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Main agent'")).firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 10), "the default bot isn't offered")
        bot.tap()
        let chip = any("composer.modelChip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no model chip in the compose sheet")
        chip.tap()
        let item = app.buttons[asked].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(asked) in the compose sheet's model menu")
        item.tap()
        let text = app.textViews["newchat.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "no text field in the compose sheet")
        text.tap()
        text.typeText(words)
        let send = app.buttons.matching(identifier: "newchat.send").allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        XCTAssertNotNil(send, "no Send in the compose sheet")
        send?.tap()
    }

    // MARK: Tests

    /// The bot card's Model row: the card stays up over the chat, so the card asks.
    func testTheBotCardsModelRowAsksOverTheCard() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let t0 = Date().timeIntervalSince1970
        openChat()
        let modelRow = openCardsModelRow()
        try auditBefore("card")
        modelRow.tap()
        let item = app.buttons[asked].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(asked) in the card's model menu")
        item.tap()
        let q = expectQuestion("over the bot card")
        XCTAssertTrue(any("profile.header").exists, "the bot card closed before its question")
        shot("model-confirm-card")
        try audit("card", q)
        q.buttons["Use \(asked)"].tap()
        XCTAssertTrue(q.waitForNonExistence(timeout: 5), "the question stayed after Use")
        XCTAssertTrue(any("profile.header").exists, "Use closed the bot card")
        XCTAssertNotNil(eventually(10) { applied(since: t0).first }, "Use didn't apply the pick")
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "hermes-4-70b"), evaluatedWith: any("profile.model"))], timeout: 10)
    }

    /// "All Models" from the card: a list over the card over the chat. The list asks; Cancel leaves the list up with
    /// nothing applied, and Use closes the list back to the card.
    func testTheListOverTheCardAsksOverItself() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let t0 = Date().timeIntervalSince1970
        openChat()
        openCardsModelRow().tap()
        let row = openListAtTheAskedModel()
        try auditBefore("list on card")
        row.tap()
        var q = expectQuestion("over the list on the card")
        XCTAssertTrue(any("models.sheet").exists, "the list closed before its question")
        shot("model-confirm-list-on-card")
        try audit("list on card", q)
        q.buttons["Cancel"].tap()
        XCTAssertTrue(q.waitForNonExistence(timeout: 5), "the question stayed after Cancel")
        XCTAssertTrue(any("models.sheet").exists, "Cancel closed the list")
        XCTAssertTrue(applied(since: t0).isEmpty, "Cancel applied the pick")
        row.tap()
        q = expectQuestion("over the list again")
        q.buttons["Use \(asked)"].tap()
        XCTAssertTrue(any("models.sheet").waitForNonExistence(timeout: 5), "Use left the list up")
        XCTAssertTrue(any("profile.header").exists, "Use closed the bot card under the list")
        XCTAssertNotNil(eventually(10) { applied(since: t0).first }, "Use didn't apply the pick")
    }

    /// "All Models" from the composer's chip: the list over the chat asks over itself, and Use closes it.
    func testTheListOverTheChatAsksOverItself() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let t0 = Date().timeIntervalSince1970
        openChat()
        let chip = any("composer.modelChip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no model chip")
        chip.tap()
        let row = openListAtTheAskedModel()
        try auditBefore("list on chat")
        row.tap()
        let q = expectQuestion("over the list on the chat")
        XCTAssertTrue(any("models.sheet").exists, "the list closed before its question")
        shot("model-confirm-list-on-chat")
        try audit("list on chat", q)
        q.buttons["Use \(asked)"].tap()
        XCTAssertTrue(any("models.sheet").waitForNonExistence(timeout: 5), "Use left the list up")
        XCTAssertNotNil(eventually(10) { applied(since: t0).first }, "Use didn't apply the pick")
    }

    /// A new chat from the compose sheet with the asked-about model: the question shows on the chat once the sheet has
    /// gone, and the first message goes only after the yes has applied.
    func testANewChatsFirstMessageWaitsForTheYes() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let words = "first words \(UUID().uuidString.prefix(6))"
        startComposedChat(words)
        let q = expectQuestion("on the new chat")
        XCTAssertNil(submit(words), "the first message went before the person answered")
        shot("model-confirm-new-chat")
        // No audit before: the question comes up on the chat as the compose sheet goes, so every unplaced issue counts.
        print("MODEL-CONFIRM-AUDIT new chat unplaced before by kind: none taken")
        try audit("new chat", q)
        q.buttons["Use \(asked)"].tap()
        let sent = try XCTUnwrap(eventually(15) { submit(words) }, "the first message didn't go after Use")
        let session = sent["session_id"] as? String
        let pick = try XCTUnwrap(applied(since: 0, session: session).first, "Use didn't apply the pick on the new chat")
        XCTAssertLessThan(pick["at"] as? Double ?? .infinity, sent["at"] as? Double ?? 0, "the first message ran before the yes applied")
        if denyTheReplysApproval() { waitForTheReplyToFinish() }
    }

    /// The same, with Cancel: the first message goes on the chat's model, nothing is applied, and the thread says so.
    func testANewChatsFirstMessageGoesOnItsModelAfterCancel() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let words = "first words \(UUID().uuidString.prefix(6))"
        startComposedChat(words)
        let q = expectQuestion("on the new chat")
        XCTAssertNil(submit(words), "the first message went before the person answered")
        q.buttons["Cancel"].tap()
        let sent = try XCTUnwrap(eventually(15) { submit(words) }, "the first message didn't go after Cancel")
        XCTAssertTrue(applied(since: 0, session: sent["session_id"] as? String).isEmpty, "Cancel applied the pick")
        XCTAssertTrue(labelled("Model unchanged").waitForExistence(timeout: 5), "the thread doesn't say the model stayed")
        if denyTheReplysApproval() { waitForTheReplyToFinish() }
    }
}
