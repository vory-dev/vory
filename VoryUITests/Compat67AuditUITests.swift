import XCTest

/// The accessibility audits for the Hermes compatibility fixes: each screen whose words or chrome changed, audited in the
/// state that shows the change, against the mock gateway in the state its group names. The gate's three types (plus
/// contrast in the Companion wizard's Credentials section). Every issue is printed ("AUDIT67 <device> <screen> <state>
/// NEW|old ..."), and a test fails only on an issue whose element is one of the elements the change touched or inside
/// one, read before the audit (an audit changes the text size and back). An issue with no element is printed and counted
/// as old: it can't be placed.
///
/// Skipped unless HERMES_E2E_URL is the mock, HERMES_E2E_BUNDLE is the demo copy, and HERMES_E2E_GROUP names the test's
/// group. The token groups read HERMES_E2E_TOKEN (or HERMES_E2E_OLD_TOKEN, the token a migrated gateway refuses); the
/// password groups read HERMES_E2E_USER and HERMES_E2E_PASSWORD, with the mock's password gate already on. Stills go to
/// HERMES_E2E_SHOTS when it is set.
@MainActor
final class Compat67AuditUITests: XCTestCase {
    private var app: XCUIApplication!
    private var base = ""
    private var bundle = ""
    private var flagged: [String] = []
    private let gate: XCUIAccessibilityAuditType = [.sufficientElementDescription, .hitRegion, .elementDetection]
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    // MARK: Setup

    private func need(_ group: String) throws {
        guard let url = env["HERMES_E2E_URL"], !url.isEmpty, let b = env["HERMES_E2E_BUNDLE"], b.hasSuffix(".demo"),
              env["HERMES_E2E_GROUP"] == group else {
            throw XCTSkip("needs the mock (HERMES_E2E_URL), the demo copy (HERMES_E2E_BUNDLE) and HERMES_E2E_GROUP=\(group)")
        }
        base = url; bundle = b
        continueAfterFailure = true
    }

    /// The demo copy on the mock with a session token, on the given tab, with any of the demo copy's own switches.
    private func launch(token: String, tab: String, extra: [String] = []) {
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", base, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", tab,
                               "-colorSchemePreference", "light"] + extra
        app.launch()
    }

    /// A fresh demo copy signed in to the mock with a username and password, through the first screen and the form.
    private func launchSigningIn(extra: [String] = []) throws {
        guard let user = env["HERMES_E2E_USER"], let password = env["HERMES_E2E_PASSWORD"], !user.isEmpty, !password.isEmpty else {
            throw XCTSkip("needs HERMES_E2E_USER and HERMES_E2E_PASSWORD (the mock's password gate)")
        }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "YES", "-colorSchemePreference", "light"] + extra
        app.launch()
        try tap(app.buttons.matching(identifier: "onboarding.getStarted"), "no first screen", timeout: 30)
        try tap(app.buttons.matching(identifier: "onboarding.skip"), "no Skip")
        try tap(app.buttons.matching(identifier: "onboarding.addGateway"), "no Connect your gateway")
        let name = try XCTUnwrap(hittable(app.textFields.matching(identifier: "gateway.name")), "no form")
        name.tap(); name.typeText("Workshop")
        let address = try XCTUnwrap(hittable(app.textFields.matching(identifier: "gateway.url")), "no address field")
        address.tap(); address.typeText(base)
        try XCTUnwrap(scrolledTo(app.descendants(matching: .any).matching(identifier: "gateway.authMethod")), "no method picker").tap()
        try tap(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Username & password'")), "no password method", timeout: 5)
        let userField = try XCTUnwrap(scrolledTo(app.textFields.matching(identifier: "gateway.username")), "no username field")
        userField.tap(); userField.typeText(user)
        let secret = try XCTUnwrap(scrolledTo(app.secureTextFields.matching(identifier: "gateway.password")), "no password field")
        secret.tap(); secret.typeText(password)
        try XCTUnwrap(scrolledTo(app.buttons.matching(identifier: "gateway.test")), "no Test Connection").tap()
        let save = app.buttons["gateway.save"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)], timeout: 40)
        save.tap()
        XCTAssertNotNil(hittable(app.buttons.matching(identifier: "chats.new"), timeout: 40), "the app did not open after Save")
    }

    // MARK: Helpers

    private var device: String { app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone" }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func labelled(_ format: String, _ args: CVarArg...) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args))
    }

    /// The first match that can be tapped and isn't under the software keyboard or, while it is there, the floating tab
    /// bar: a row under the bar still reads as hittable, but a tap at its middle lands on the bar. iOS's own "Save
    /// Password?" sheet, which comes up over the app when a form with a password goes away, is answered Not Now on the
    /// way, as RememberSignInUITests does.
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let prompt = app.sheets.matching(NSPredicate(format: "label CONTAINS 'Save Password'")).firstMatch
            if prompt.exists, prompt.buttons["Not Now"].exists { prompt.buttons["Not Now"].tap() }
            let keyboard = app.keyboards.firstMatch
            let covered = keyboard.exists ? keyboard.frame : .null
            let bar = tabBarArea()
            if let e = query.allElementsBoundByIndex.first(where: {
                $0.isHittable && !$0.frame.intersects(covered)
                    && (isBarButton($0) || !bar.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)))
            }) { return e }
            pause(0.3)
        }
        return nil
    }

    /// The floating tab bar's area while its buttons can be tapped: from the top of its buttons to the foot of the screen,
    /// across the screen; nothing when there is no bar, or when a sheet is over it (its buttons are there but not hittable).
    private func tabBarArea() -> CGRect {
        let buttons = all(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' OR identifier == 'chats.new'")))
            .filter(\.isHittable)
        guard let top = buttons.map(\.frame.minY).min() else { return .null }
        let screen = app.frame
        return CGRect(x: screen.minX, y: top - 4, width: screen.width, height: screen.maxY - top + 4)
    }

    /// One of the tab bar's own buttons, which the bar's area never hides.
    private func isBarButton(_ e: XCUIElement) -> Bool { e.identifier.hasPrefix("tab.") || e.identifier == "chats.new" }

    private func tap(_ query: XCUIElementQuery, _ what: String, timeout: TimeInterval = 10) throws {
        try XCTUnwrap(hittable(query, timeout: timeout), what).tap()
    }

    /// Scrolls up until the element is on screen.
    private func scrolledTo(_ query: XCUIElementQuery, swipes: Int = 8) -> XCUIElement? {
        var e = hittable(query, timeout: 2)
        var n = 0
        while e == nil, n < swipes {
            app.swipeUp(velocity: .slow)
            n += 1
            e = hittable(query, timeout: 2)
        }
        return e
    }

    /// Settings, then its row `id`.
    private func openSettings(_ id: String) throws {
        try tap(app.buttons.matching(identifier: "tab.settings"), "no Settings tab", timeout: 40)
        try XCTUnwrap(scrolledTo(app.buttons.matching(identifier: "settings.row.\(id)")), "no \(id) row in Settings").tap()
        pause(1.5)
    }

    private func all(_ query: XCUIElementQuery) -> [XCUIElement] { query.allElementsBoundByIndex.filter(\.exists) }

    /// Taps a field until it takes the keyboard's focus, three taps at most: a tap that lands while a sheet settles can
    /// leave the focus where it was. The field, or nil when it never took the focus.
    private func focused(_ field: XCUIElement) -> XCUIElement? {
        let has = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<3 {
            field.tap()
            if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: has, object: field)], timeout: 2) == .completed { return field }
        }
        return nil
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        guard let dir = env["HERMES_E2E_SHOTS"], !dir.isEmpty else { return }
        let d = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("audit67-\(name).png"))
    }

    /// One call to the mock's own controls, answered as JSON (RememberSignInUITests' form).
    private func mock(_ method: String, _ path: String) -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        URLSession.shared.dataTask(with: req) { data, _, _ in
            answer.json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return answer.json
    }

    /// The mock's answer, handed from URLSession's queue to the test (the semaphore orders them).
    private final class Answer: @unchecked Sendable { var json: [String: Any]? }

    /// One element as the audit names it: its type, its label and its frame. A nested type isn't main-actor isolated
    /// with its class, so the init that reads the element is.
    private struct Key {
        let type: UInt, label: String, frame: CGRect
        @MainActor init(_ e: XCUIElement) { type = e.elementType.rawValue; label = e.label; frame = e.frame }
        /// The same type and label, and the frame within 2 points on every side: the issue's element is read again after
        /// the audit has changed the text size and back.
        func matches(_ o: Key) -> Bool {
            type == o.type && label == o.label
                && abs(frame.minX - o.frame.minX) <= 2 && abs(frame.minY - o.frame.minY) <= 2
                && abs(frame.maxX - o.frame.maxX) <= 2 && abs(frame.maxY - o.frame.maxY) <= 2
        }
    }

    /// Audits the screen as it stands. The changed elements are `changed` and every element whose label holds one of
    /// `phrases`, each with its descendants, read before the call. An issue is NEW only when its element is one of them,
    /// so an older element under a sheet stays old wherever its frame lies.
    private func audit(_ screen: String, _ state: String, changed: [XCUIElement], phrases: [String] = [], contrast: Bool = false) throws {
        let d = device
        let tops = changed.filter(\.exists) + phrases.flatMap { all(labelled("label CONTAINS %@", $0)) }
        let keys = tops.flatMap { [Key($0)] + $0.descendants(matching: .any).allElementsBoundByIndex.filter(\.exists).map(Key.init) }
        print("AUDIT67 \(d) \(screen) \(state) changed \(tops.count) at \(tops.map(\.frame)), \(keys.count) with their descendants")
        shot("\(screen)-\(state)")
        var types = gate
        if contrast { types.insert(.contrast) }
        var found: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            let el = issue.element
            let new = el.map { e in let k = Key(e); return keys.contains { $0.matches(k) } } ?? false
            let line = "\(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)"
            print("AUDIT67 \(d) \(screen) \(state) \(new ? "NEW" : "old") \(line)")
            if new { found.append("\(screen) \(state): \(line)") }
            return true
        }
        flagged += found
    }

    /// The sign-in banner over the chat list, found by its button: its second line (`line`, a phrase of it), what this
    /// release changes in it. Its title and button are older; they are audited and printed, not judged.
    private func banner(line: String, timeout: TimeInterval) -> [XCUIElement] {
        guard hittable(app.buttons.matching(identifier: "signin.banner"), timeout: timeout) != nil else { return [] }
        return all(labelled("label CONTAINS %@", line))
    }

    // MARK: A, a migrated gateway refusing the configured session token (rows 1 to 5)

    func testA_aRefusedSessionTokenIsSaidAccessibly() throws {
        try need("A")
        let token = try XCTUnwrap(env["HERMES_E2E_OLD_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }, "needs HERMES_E2E_OLD_TOKEN")
        let words = ["webapp/session-token", "after a Hermes update"]

        // 5: the chat list's sign-in banner.
        launch(token: token, tab: "chats")
        let b = banner(line: "is not signed in to this gateway", timeout: 40)
        XCTAssertFalse(b.isEmpty, "no sign-in banner over the chat list, or none with its second line")
        try audit("chats", "token-refused", changed: b)

        // 1: Status's Sign-in row.
        try openSettings("status")
        let signIn = try XCTUnwrap(hittable(labelled("label BEGINSWITH 'Sign-in: '"), timeout: 15), "no Sign-in row on Status")
        try audit("status", "token-refused", changed: [signIn])

        // 3: the gateway form the row opens, after its connection test.
        signIn.tap()
        try XCTUnwrap(scrolledTo(app.buttons.matching(identifier: "gateway.test")), "no Test Connection").tap()
        pause(10)
        let formWords = all(labelled("label CONTAINS 'webapp/session-token' OR label CONTAINS 'public_url'"))
        XCTAssertFalse(formWords.isEmpty, "the form shows neither the token's file nor the public address words")
        try audit("gateway-form", "token-refused", changed: formWords, phrases: words + ["public_url"])

        // 2: Settings > Gateways, its refused line and Sign in again.
        launch(token: token, tab: "settings")
        try openSettings("gateways")
        let refused = all(labelled("label CONTAINS 'webapp/session-token'")) + all(labelled("label == 'Sign in again'"))
        XCTAssertFalse(refused.isEmpty, "Gateways doesn't say the token was refused")
        try audit("gateways", "token-refused", changed: refused, phrases: words)

        // 4: Troubleshooting's two changed lines, each audited on screen (a list's rows off screen aren't there to audit).
        launch(token: token, tab: "settings")
        try openSettings("troubleshooting")
        for (n, phrase) in ["webapp/session-token", "sign in again here first"].enumerated() {
            let line = try XCTUnwrap(scrolledTo(labelled("label CONTAINS %@", phrase)), "no Troubleshooting line with '\(phrase)'")
            try audit("troubleshooting", "line\(n + 1)", changed: [line], phrases: [phrase])
        }
        XCTAssertTrue(flagged.isEmpty, "the audit flags the changed elements: \(flagged)")
    }

    // MARK: B, a password sign-in the gateway has ended (row 6)

    func testB_anEndedSignInIsSaidAccessibly() throws {
        try need("B")
        try launchSigningIn()
        // Every access and refresh token goes, then the sockets drop, so the app's refresh is turned down.
        XCTAssertNotNil(mock("POST", "/api/_mock/expire-sessions"), "the mock didn't expire the sessions")
        _ = mock("GET", "/mock/drop-sockets")
        let ended = "A Hermes update can end every sign-in once"
        let b = banner(line: ended, timeout: 60)
        XCTAssertFalse(b.isEmpty, "no sign-in banner after the sign-in ended")
        XCTAssertTrue(labelled("label CONTAINS %@", ended).firstMatch.exists, "the banner doesn't say the sign-in ended")
        try audit("chats", "sign-in-ended", changed: b, phrases: [ended])
        try openSettings("status")
        let signIn = try XCTUnwrap(hittable(labelled("label BEGINSWITH 'Sign-in: '"), timeout: 15), "no Sign-in row on Status")
        try audit("status", "sign-in-ended", changed: [signIn])
        XCTAssertTrue(flagged.isEmpty, "the audit flags the changed elements: \(flagged)")
    }

    // MARK: C, a gateway restarting (row 7)

    func testC_aRestartIsSaidAccessibly() throws {
        try need("C")
        let token = try XCTUnwrap(env["HERMES_E2E_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }, "needs HERMES_E2E_TOKEN")
        // The mock is left as it was found, whatever happens below.
        defer { _ = mock("GET", "/mock/fault?mode=none") }
        launch(token: token, tab: "chats")
        XCTAssertNotNil(hittable(app.buttons.matching(identifier: "chats.new"), timeout: 40), "the app did not come up")
        XCTAssertNotNil(mock("GET", "/mock/fault?mode=draining&count=120"), "the mock's fault switch didn't answer")
        // The Chats menu's connection line, read with the menu open (ReconnectFaultUITests' chip).
        let restarting = labelled("label CONTAINS[c] 'restarting'")
        var line: XCUIElement?
        for _ in 0..<12 where line == nil {
            if let chip = hittable(labelled("identifier == 'chats.profile' OR label BEGINSWITH 'Profile: '"), timeout: 10) { chip.tap() }
            pause(0.8)
            line = all(restarting).first
            if line == nil { app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap(); pause(3) }
        }
        let menuLine = try XCTUnwrap(line, "the Chats menu never said the gateway is restarting")
        try audit("chats-menu", "restarting", changed: [menuLine] + all(app.buttons.matching(NSPredicate(format: "label == 'Reconnect'"))))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap(); pause(0.8)
        try openSettings("status")
        let gateway = try XCTUnwrap(hittable(labelled("label BEGINSWITH 'Gateway: ' AND label CONTAINS[c] 'restarting'"), timeout: 20),
                                    "Status's Gateway row doesn't say the gateway is restarting")
        try audit("status", "restarting", changed: [gateway])

        // The screen that waits for the unlock, opened by the demo copy's own switch (every saved-gateway read refused):
        // its title, its words and its lock are all new.
        launch(token: token, tab: "chats", extra: ["-vory-demo-keychain-locked"])
        let waiting = try XCTUnwrap(hittable(labelled("label == 'Waiting for Unlock'"), timeout: 30), "the app didn't wait for the unlock")
        let screen = [waiting] + all(labelled("label BEGINSWITH 'Vory reads your saved gateways once'")) + all(labelled("label == 'Lock'"))
        try audit("waiting", "keychain-locked", changed: screen)
        XCTAssertTrue(flagged.isEmpty, "the audit flags the changed elements: \(flagged)")
    }

    // MARK: D, an older companion on the gateway (row 8)

    func testD_anOlderCompanionIsSaidAccessibly() throws {
        try need("D")
        let token = try XCTUnwrap(env["HERMES_E2E_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }, "needs HERMES_E2E_TOKEN")
        launch(token: token, tab: "settings")
        try openSettings("status")
        let row = try XCTUnwrap(hittable(labelled("label BEGINSWITH 'Companion: ' AND label CONTAINS 'Update it from Settings'"), timeout: 30),
                                "Status's Companion row doesn't ask for the update")
        try audit("status", "older-companion", changed: [row])
        XCTAssertTrue(flagged.isEmpty, "the audit flags the changed elements: \(flagged)")
    }

    // MARK: E1 and E2, the Companion wizard's Credentials section (rows 9 and 10)

    func testE1_aSignedInCompanionIsSaidAccessibly() throws {
        try need("E1")
        try credentials(state: "signed-in", row: "label BEGINSWITH 'Signed in'")
    }

    func testE2_aTurnedDownCompanionSignInIsSaidAccessibly() throws {
        try need("E2")
        try credentials(state: "turned-down", row: "label == \"The gateway turned down the companion's sign-in\"")
    }

    /// Signed in with a password, the wizard opened on its sign-in step (`-vory-setup-signin`), the companion's own
    /// sign-in made in its sheet, then the Credentials section audited with contrast.
    private func credentials(state: String, row: String) throws {
        try launchSigningIn(extra: ["-vory-setup-signin"])
        try openSettings("companion")
        try tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Configure'")), "no Configure on the Companion page", timeout: 20)
        try tap(app.buttons.matching(NSPredicate(format: "label == 'Sign in for the companion'")), "the wizard isn't on its sign-in step", timeout: 20)
        let user = env["HERMES_E2E_USER"] ?? "", password = env["HERMES_E2E_PASSWORD"] ?? ""
        let userField = try XCTUnwrap(hittable(app.textFields.matching(NSPredicate(format: "placeholderValue == 'Username'"))), "no Username field")
        userField.tap(); userField.typeText(user)
        let secret = try XCTUnwrap(hittable(app.secureTextFields.matching(NSPredicate(format: "placeholderValue == 'Password'"))), "no Password field")
        try XCTUnwrap(focused(secret), "the Password field never took the keyboard's focus (three taps)").typeText(password)
        try tap(app.buttons.matching(NSPredicate(format: "label == 'Sign in'")), "no Sign in in the sheet")
        let label = try XCTUnwrap(hittable(labelled(row), timeout: 30), "the Credentials section doesn't show the \(state) row")
        pause(1)
        // Only what this release adds to the section: the state's row and, when the sign-in was turned down, its line.
        // The section's other controls and the chat under the sheet are older; they are audited and printed, not judged.
        let section = [label] + all(labelled("label BEGINSWITH 'Sign in again, then install'"))
        try audit("companion-credentials", state, changed: section, contrast: true)
        XCTAssertTrue(flagged.isEmpty, "the audit flags the Credentials section: \(flagged)")
    }
}
