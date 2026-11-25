import XCTest

/// The closed Duo's tab capsule under a chat's push and pop (the capsule rides under the page, not on its own timer), and
/// #755 (the Board's options at the Board tab's root).
///
/// The capsule leaves the accessibility tree as a chat opens, so its drawn part is read from the bar's DEBUG frame log
/// (`-vory-morph-frames -vory-morph-log`, the `debug.morphlog` element): each drawn frame of the ride is a line
/// "<wall time> ride <minX> <edge> <shown width> <capsule width> <scene>", the page's leading edge and the capsule's part
/// drawn to the leading side of it. The log check guards the mask's arithmetic only; what the eye sees (no ghost, no cut)
/// is read from recorded frames, not here.
@MainActor
final class StripRide66UITests: XCTestCase {
    private var app: XCUIApplication!

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// The closed Duo's strip: the window taller than wide, and the tab capsule standing at its trailing edge.
    private var closedStrip: Bool {
        let w = app.windows.firstMatch.frame, tab = any("tab.chats")
        return w.height > w.width && tab.exists && tab.frame.minX > w.width - 120
    }

    /// The demo on Chats, with the bar's frame log on.
    private func launchDemo() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats", "-restore.openChat", "none",
                               "-colorSchemePreference", "light", "-vory-morph-frames", "-vory-morph-log"]
        app.launch()
    }

    /// The "ride" lines of the frame log: (edge, the capsule's minX, the part drawn).
    private func rideLines() -> [(edge: Double, minX: Double, shown: Double)] {
        let text = (any("debug.morphlog").value as? String) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ")
            guard p.count >= 6, p[1] == "ride", let minX = Double(p[2]), let edge = Double(p[3]), let shown = Double(p[4]) else { return nil }
            return (edge, minX, shown)
        }
    }

    /// Open the first demo chat and go back, twice; every drawn frame of the ride keeps the capsule to the leading side
    /// of the page's edge, the push and the pop are both followed (lines with the edge between the two ends), and the
    /// capsule is back and in reach after each pop.
    func testTheCapsuleRidesUnderAChatOnTheClosedStrip() throws {
        try launchDemo()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (identifier BEGINSWITH 'chat.')", "Packing list for the lake weekend")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no demo chat row")
        guard closedStrip else { throw XCTSkip("not the closed Duo's strip") }
        let back = app.buttons["chat.back"].firstMatch, chats = any("tab.chats")
        for round in 1...2 {
            row.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 5), "round \(round): no Back")
            pause(1.5)
            XCTAssertFalse(chats.isHittable, "round \(round): the capsule is in reach over the chat")
            back.tap()
            pause(1.5)
            XCTAssertTrue(chats.waitForExistence(timeout: 3) && chats.isHittable, "round \(round): the capsule isn't back after the pop")
        }
        let lines = rideLines()
        let width = app.windows.firstMatch.frame.width
        let between = lines.filter { $0.edge > 1 && $0.edge < width - 1 }
        print("RIDE66 lines \(lines.count), between the ends \(between.count)")
        XCTAssertGreaterThanOrEqual(between.count, 8, "the ride wasn't followed frame by frame (\(between.count) lines mid-slide)")
        // This guards the mask's arithmetic only (no part drawn past the page's edge; a fully covered capsule draws
        // nothing). What the eye sees, no ghost and no cut, is read from recorded frames, not here.
        for l in lines {
            XCTAssertTrue(l.shown == 0 || l.minX + l.shown <= l.edge + 0.5,
                          "the capsule drawn past the page's edge: edge \(l.edge), minX \(l.minX), shown \(l.shown)")
        }
    }

    /// #755: at the Board tab's root, the bar's Board options opens the board's menu (Refresh), on the mock gateway
    /// (the Board needs its plugin; HERMES_E2E_URL and HERMES_E2E_TOKEN, as PageOwnButtonsUITests). On the iPhone and the
    /// closed Duo, where the bar draws it.
    func testTheBoardOptionsAtTheBoardsRootOpenItsMenu() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let args = ["-companionPromptShown", "YES", "-launchTab", "kanban", "-colorSchemePreference", "light",
                    "-tabLayout", "chats,kanban,settings", "-tabLayout.homeFirstApplied", "YES"]
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
        if app.windows.firstMatch.frame.width > 700 { throw XCTSkip("the morph bar is the phone's and the closed Duo's") }
        let options = any("board.options")
        XCTAssertTrue(options.waitForExistence(timeout: 15) && options.isHittable, "no Board options at the Board's root")
        options.tap()
        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 5), "Board options at the root has no Refresh (#755)")
        XCTAssertTrue(app.buttons["Nudge Dispatcher"].exists, "Board options at the root has no Nudge Dispatcher (#755)")
        app.buttons["Refresh"].tap()
        pause(1)
        XCTAssertTrue(options.isHittable, "the Board's root lost its bar after Refresh")
    }
}
