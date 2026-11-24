import XCTest
import os

/// #729 (2026-11-18): 58 against 61 on one long chat full of rich rows, read from the app's own GEO lines
/// (`-vory-geometry-log`) and this test's MARK lines, both in the perf log (subsystem Vory, category perf) that the runner
/// streams from the simulator. The test only drives and marks; every verdict is the runner's, by rules written before the
/// run. Skipped unless HERMES_E2E_URL and HERMES_E2E_TOKEN are set: the repo's mock gateway with MOCK_DIGEST=40, whose
/// seeded chat then holds 40 rounds of a question, a reply with its reasoning, 3 to 5 tool rows and a long digest
/// (headings, lists, a code block, a table, an image every fifth round): 279 messages, one item each.
///
/// Env: HERMES_E2E_URL, HERMES_E2E_TOKEN, HERMES_E2E_BUNDLE (the demo copy), T729_CHAT (default the mock's seeded chat,
/// "Disk cleanup on the log host"), T729_DRAG (pt, 100 to 500, default 300), T729_REST (s, 1 to 5, default 1.5).
///
/// Three legs in one launch, each marked at its start and end and at every drag:
/// - A: the chat's first open from Chats (its history from the gateway), then at once 6 drags up, 0.2 s apart.
/// - B: back, the chat reopened from the rows the device kept, 1 s, then the same 6 drags.
/// - C: back, reopened, 3 s at its end, then 10 drags up, each followed by T729_REST s at rest.
/// A drag: a press at the window's middle column at 35% of its height, held 0.05 s, a drag of T729_DRAG pt down (the
/// thread moves up its history) at the slow velocity, held 0.3 s before the lift, so the scroll ends with no glide.
/// Nothing is set: no orientation, look or text size; the window is read only.
@MainActor
final class Thread729UITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private let perf = Logger(subsystem: "Vory", category: "perf")

    /// One line to the test's log and the same line to the perf log, where the runner reads it beside the GEO lines.
    private func say(_ s: String) {
        print("T729 \(s)")
        perf.notice("T729 \(s, privacy: .public)")
    }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func f(_ r: CGRect) -> String { String(format: "(%.1f,%.1f,%.1f,%.1f)", r.minX, r.minY, r.width, r.height) }
    private func number(_ key: String, _ fallback: Double, _ low: Double, _ high: Double) -> Double {
        guard let v = env[key].flatMap(Double.init), v >= low, v <= high else { return fallback }
        return v
    }
    private var chat: String { env["T729_CHAT"].flatMap { $0.isEmpty ? nil : $0 } ?? "Disk cleanup on the log host" }
    private var dragPt: Double { number("T729_DRAG", 300, 100, 500) }
    private var rest: Double { number("T729_REST", 1.5, 1, 5) }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.2)
        } while Date() < deadline
        return nil
    }
    /// Every message row, by the prefix every row's identifier has (`thread.row.<kind>`).
    private var rows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread.row."))
    }
    private var listRow: XCUIElementQuery { app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", chat)) }
    private var back: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "chat.back") }

    private func void(_ why: String) {
        say("VOID \(why); window \(f(app.windows.firstMatch.frame))")
        XCTFail("T729 VOID: \(why)")
    }

    /// The chat opened from the list: true once a row of it exists (shown or still out of sight while its history lands).
    private func open(_ leg: String) -> Bool {
        guard let r = hittable(listRow, timeout: 20) else { void("\(leg): the chat '\(chat)' isn't in the list"); return false }
        say("MARK \(leg) open")
        r.tap()
        guard rows.firstMatch.waitForExistence(timeout: 20) else { void("\(leg): the chat showed no row in 20 s"); return false }
        say("MARK \(leg) row")
        return true
    }
    private func goBack(_ leg: String) -> Bool {
        guard let b = hittable(back, timeout: 10) else { void("\(leg): no back button"); return false }
        b.tap()
        say("MARK \(leg) back")
        pause(1)
        return true
    }
    private func drag(_ leg: String, _ k: Int) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = start.withOffset(CGVector(dx: 0, dy: dragPt))
        say("MARK \(leg) drag \(k) begin")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        say("MARK \(leg) drag \(k) end")
    }

    func testThread729() throws {
        guard let url = env["HERMES_E2E_URL"], let token = env["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        guard let bundle = env["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { XCTFail("T729 VOID: HERMES_E2E_BUNDLE not set"); return }
        app = XCUIApplication(bundleIdentifier: bundle)
        // As ThreadEndsUITests launches (the mock as the gateway, on the chat list, no chat restored), plus the GEO lines.
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-restore.openChat", "none", "-vory-geometry-log"]
        app.launch()
        say("SETUP launched; window \(f(app.windows.firstMatch.frame)); orientation \(XCUIDevice.shared.orientation.rawValue); drag \(Int(dragPt)) pt, rest \(rest) s")

        // A: the first open, its history from the gateway, and at once the drags.
        say("MARK A start")
        guard open("A") else { return }
        for k in 1...6 { drag("A", k); pause(0.2) }
        pause(1)
        say("MARK A end")
        guard goBack("A") else { return }

        // B: reopened from the kept rows, a second, then the same drags.
        say("MARK B start")
        guard open("B") else { return }
        pause(1)
        for k in 1...6 { drag("B", k); pause(0.2) }
        pause(1)
        say("MARK B end")
        guard goBack("B") else { return }

        // C: reopened, at rest at its end, then each drag followed by a rest.
        say("MARK C start")
        guard open("C") else { return }
        pause(3)
        for k in 1...10 {
            drag("C", k)
            pause(rest)
            say("MARK C rest \(k) end")
        }
        say("MARK C end")
        say("DONE; window \(f(app.windows.firstMatch.frame))")
    }
}
