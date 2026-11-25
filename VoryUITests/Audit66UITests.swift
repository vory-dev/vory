import XCTest

/// 66's accessibility audit (performAccessibilityAudit) on the touched screens the existing suites don't carry,
/// light and dark (the three screens below). Every issue the audit raises is printed ("AUDIT66 ...")
/// and attached; the test fails only on an issue lying on a control 66 touched, as TabBarGapsUITests'
/// testTabBarAuditClean does for its bar:
///   1. Chats on the closed Duo, back from a chat: the tab capsule (the `tab.*` controls and the compose and voice
///      circles), which the capsule's ride now covers and uncovers with the page.
///   2. The Board tab's root with its options menu open (#755): `board.options`, `board.new`, and the menu's two items.
///   3. The Board pushed from Settings (#435's case, unchanged by 66, re-audited): the bar's Back, `board.options`
///      and `board.new`.
/// 1 runs on the demo (HERMES_E2E_BUNDLE); 2 and 3 on the mock gateway (HERMES_E2E_URL and HERMES_E2E_TOKEN; 3 also its
/// one-board mode, HERMES_E2E_ARGS with "one-board"). Each skips where its screen isn't: 1 off the closed strip, 2 and 3 on a
/// wide window (no morph bar).
@MainActor
final class Audit66UITests: XCTestCase {
    private var app: XCUIApplication!
    private let e = ProcessInfo.processInfo.environment

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private var wide: Bool { app.windows.firstMatch.frame.width > 700 }

    private func launch(_ args: [String], mock: Bool) throws {
        let bundle = e["HERMES_E2E_BUNDLE"] ?? ""
        if mock {
            guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
            app = bundle.isEmpty ? XCUIApplication() : XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = (bundle.isEmpty ? [] : ["-vory-demo-gateway", url, token, "Workshop"]) + args
        } else {
            guard !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo"] + args
        }
        app.launch()
    }

    /// The audit, every issue printed and attached; the issues whose element lies within `touched` returned.
    private func audit(_ name: String, touched: [CGRect]) throws -> [String] {
        var flagged: [String] = []
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "audit66-\(name)"; shot.lifetime = .keepAlways; add(shot)
        try app.performAccessibilityAudit { issue in
            let el = issue.element
            let line = "\(issue.auditType) '\(issue.compactDescription)' id '\(el?.identifier ?? "")' label '\(el?.label ?? "")' frame \(el.map { "\($0.frame)" } ?? "-")"
            print("AUDIT66 \(name) \(line)")
            if let f = el?.frame, touched.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(f) }) { flagged.append(line) }
            return true
        }
        print("AUDIT66 \(name) done, \(flagged.count) on the touched controls")
        return flagged
    }

    /// 1: Chats on the closed Duo, back from a chat, light and dark.
    func testChatsBackFromAChatOnTheClosedStrip() throws {
        for look in ["light", "dark"] {
            try launch(["-companionPromptShown", "YES", "-launchTab", "chats", "-restore.openChat", "none", "-colorSchemePreference", look], mock: false)
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (identifier BEGINSWITH 'chat.')", "Packing list for the lake weekend")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "no demo chat row")
            let w = app.windows.firstMatch.frame, chats = any("tab.chats")
            guard w.height > w.width, chats.exists, chats.frame.minX > w.width - 120 else { throw XCTSkip("not the closed Duo's strip") }
            row.tap()
            let back = app.buttons["chat.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back")
            pause(1.5); back.tap(); pause(1.5)
            XCTAssertTrue(chats.waitForExistence(timeout: 3) && chats.isHittable, "the capsule isn't back")
            let parts = ["tab.dashboard", "tab.chats", "tab.status", "tab.settings", "chats.voice", "chats.new"].map { any($0) }.filter { $0.exists }.map(\.frame)
            let flagged = try audit("chats-closed-\(look)", touched: parts)
            XCTAssertTrue(flagged.isEmpty, "\(look): the audit flags the capsule: \(flagged)")
            app.terminate()
        }
    }

    /// 2: the Board tab's root with its options menu open (#755), light and dark.
    func testTheBoardsRootWithItsMenuOpen() throws {
        for look in ["light", "dark"] {
            try launch(["-companionPromptShown", "YES", "-launchTab", "kanban", "-colorSchemePreference", look,
                        "-tabLayout", "chats,kanban,settings", "-tabLayout.homeFirstApplied", "YES"], mock: true)
            if wide { throw XCTSkip("the morph bar is the phone's and the closed Duo's") }
            let options = any("board.options"), add = any("board.new")
            XCTAssertTrue(options.waitForExistence(timeout: 15), "no Board options")
            var touched = [options.frame, add.frame]
            options.tap()
            let refresh = app.buttons["Refresh"].firstMatch, nudge = app.buttons["Nudge Dispatcher"].firstMatch
            XCTAssertTrue(refresh.waitForExistence(timeout: 5), "no Refresh in the menu")
            touched += [refresh.frame, nudge.frame]
            let flagged = try audit("board-root-menu-\(look)", touched: touched)
            XCTAssertTrue(flagged.isEmpty, "\(look): the audit flags the Board's bar or its menu: \(flagged)")
            app.terminate()
        }
    }

    /// 3: the Board pushed from Settings, on the mock's one-board mode (#435's case), light and dark.
    func testTheBoardPushedFromSettings() throws {
        guard (e["HERMES_E2E_ARGS"] ?? "").contains("one-board") else { throw XCTSkip("the mock is not in its one-board mode") }
        for look in ["light", "dark"] {
            try launch(["-companionPromptShown", "YES", "-launchTab", "settings", "-colorSchemePreference", look,
                        "-tabLayout", "chats,projects,cron,settings", "-tabLayout.homeFirstApplied", "YES"], mock: true)
            if wide { throw XCTSkip("the morph bar is the phone's and the closed Duo's") }
            // As PageOwnButtonsUITests' openSettingsRow: the row clear of the tab bar, the list moved up until it is.
            let row = any("settings.row.kanban")
            XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 20), "no Settings rows")
            let limit = app.windows.firstMatch.frame.maxY - 150
            for _ in 0..<12 where !(row.exists && row.isHittable && row.frame.maxY < limit) { app.swipeUp(velocity: .slow); pause(0.5) }
            XCTAssertTrue(row.exists && row.isHittable, "no Board row on Settings")
            row.tap(); pause(1.5)
            let options = any("board.options"), add = any("board.new"), back = any("chat.back").exists ? any("chat.back") : app.buttons["Back"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add task in the bar")
            let flagged = try audit("board-pushed-\(look)", touched: [options.frame, add.frame, back.frame].filter { $0.width > 0 })
            XCTAssertTrue(flagged.isEmpty, "\(look): the audit flags the pushed Board's bar: \(flagged)")
            app.terminate()
        }
    }
}
