import XCTest
import os

/// #729's paging (65): scrolling up a long chat holds the reader's place. This is the drawn-place test. It must fail on
/// 64 (a jump) and pass with paging, on the device where 64 fails at least 4 of 5 runs.
///
/// It is skipped unless HERMES_E2E_URL and HERMES_E2E_TOKEN are set: the repo's mock gateway with MOCK_TALL=near and
/// MOCK_LONG=3. The tall chat then holds three copies of its 98 rows (short rounds, a tall block of tables, an 80-line
/// code block and a 34-paragraph reply, then short rounds): 294 rows, with fresh row ids from the mock.
/// The streaming leg is the same test with the mock's MOCK_WORKING set to the chat's title words, so a reply streams at
/// its end while the reader is up the thread. The runner sets that; the test only says it (T729_STREAMING).
///
/// Env:
/// - HERMES_E2E_URL, HERMES_E2E_TOKEN, HERMES_E2E_BUNDLE (the demo copy);
/// - T729_CHAT (default "Disk cleanup on the log host");
/// - T729_DRAG (pt, 100 to 500, default 300);
/// - T729_REST (s, 0.5 to 5, default 1.5);
/// - T729_DRAGS (the most drags, 10 to 600, default 400);
/// - T729_STREAMING (said in the log only);
/// - T729_MODE (v4: slow, the default; reopen; or fast);
/// - T729_OPEN_WAIT (v7: s, 0.5 to 3, default 3; for validation only).
///
/// The test opens the chat from Chats, waits 3 s at its end, then drags up, each drag followed by a rest. A drag is a
/// press at the window's middle column at 35% of its height, held 0.05 s, a drag of T729_DRAG pt down (the thread moves
/// up its history) at the slow velocity, held 0.3 s before the lift, so the scroll ends with no glide (as testThread729).
///
/// v4, the modes (the measured drags after them are always the slow ones below):
/// - slow: as v3. The first open, 3 s at the end, then the measured drags.
/// - reopen: as testThread729's legs A, B and C, where 64 jumped on the closed Duo (r10 duo d1, leg C 3 of 3). Open,
///   6 slow drags at once 0.2 s apart (unmeasured, "MARK P priorA drag <k>"), back; open, 1 s, 6 slow drags 0.2 s apart
///   ("MARK P priorB drag <k>"), back; then the third open, from the kept rows, 3 s at its end, and the measured drags.
/// - fast: the first open, and at once, with no 3 s wait, 6 flings (`.fast`, no hold before the lift, so they glide),
///   while rows are still loading. After each fling:
///   - it settles: reads 0.5 s apart until the reference moved under 1 pt between two reads, 3 s at most. One that
///     doesn't settle in 3 s is a JUMP ("JUMP unsettled", with the last move's size);
///   - the still check: with no finger, 1.5 s more, and the reference must not move over the tolerance. A move over it,
///     or the reference gone from the window, is a JUMP ("JUMP drift"): the place moving with nobody touching.
///   Then the measured drags. Flings don't count toward T729_DRAGS; they're always 6.
/// - Every mode, each measured drag: an early read just after the lift, beside the late read after the rest. When the
///   late read holds and the early one is off the drag's place by more than the tolerance, or doesn't find the row, it
///   says "MARK P transient drag <k>" with both: a marker for the run's video, never a JUMP by itself.
///
/// The drawn place, per drag:
/// - Each message row is one element (`.contain`) with the identifier `thread.row.<kind>` and no label of its own (v2:
///   v1 read the row's own label, which is empty, and every run on 64 read VOID). A row's key is its own label if it
///   has one, else the first 3 non-empty labels inside it, depth first, joined by " | " and cut at 120 characters. Its
///   frame is the row element's own. A row with no key is never the reference.
/// - Before the drag, the reference is the keyed row nearest the window's middle. The place keeper holds the row under
///   the middle, so this is the row the reader is on. With streaming on (T729_STREAMING set and not "0"), the last row
///   in the snapshot is never the reference: its text grows, so its key changes. If it's the only keyed row in the
///   window, the test makes a lead-in drag ("MARK P lead-in drag <k>"), with nothing measured and no JUMP read, and
///   follows the first other row that comes in. At most 3 lead-in drags, then VOID. Lead-in drags count toward
///   T729_DRAGS. With streaming off (tall3), the last row can be the reference, as in v1.
/// - After the rest, it is found again by its key, exactly: the copy nearest where the drag should have put it, since
///   the long fixture repeats its texts, but thousands of points apart.
/// - It must have moved down by the drag less the touch's slop (10 pt), within 40 pt. More than that, or no copy of it
///   in the window, is a JUMP, said with its kind ("JUMP left ..." when no copy is in the window, the only lines with the
///   words "left the window"; "JUMP offset ..." for every other measured drag), its size and its step. v4's flings add
///   "JUMP unsettled ..." and "JUMP drift ..." (above); neither ever says "left the window".
/// - At "MARK P start" the test says how many `thread.row.` elements it read and how many had a key.
/// - v6, streaming on only: a measured drag that starts while the thread is stuck to the end with a reply streaming is
///   a lead-in too. While stuck, the thread follows the growing reply, so the rows above it rise by themselves; a rise
///   between the reference's read and the finger's landing is not the drag's and not a jump. Two tests decide it, and
///   only when the last row is in the window:
///   - by position: at "MARK P start" (the open, then 3 s at its end, so stuck) the last row's frame bottom is the stuck
///     bottom, B0, said in that line. B0 is used when the last row is in the window and B0 lies from two thirds of the
///     window's height (from its top) to its bottom; else the position test is off for the run and the line says so,
///     with B0's value. Stuck by position: the last row in the window with its bottom within 8 pt of B0, either side.
///   - by follow: a second read 0.3 s after the first; the reference rose by itself, 1 to 60 pt; and the thread is at
///     the end: the last row's bottom within 60 pt of B0, or, with the position test off, in the window's lower third
///     (a rise anywhere else, such as a row appearing above, is measured).
///   - the guard: a move of the reference between the two reads over 60 pt, or downward by more than 1 pt, or the
///     reference gone from the window in the second read, is never a lead-in. That drag is measured from the first read,
///     as in v4, so the move counts in it as a jump or a rest move.
///   Such a lead-in says "MARK P lead-in drag <k>: stuck to the end with a reply streaming (by position|follow|both;
///   ...)", which names the test that decided it. It counts toward T729_DRAGS and toward the 3 lead-in drags before a
///   VOID, with v4's lead-ins. With streaming off, nothing here applies and the test is v4's.
/// - v7, streaming on only, two additions:
///   - by growth: when v6 doesn't excuse the drag, the same two reads are checked once more. The reference rose; the
///     last row is wholly in the window at both reads; its bottom is pinned (within 8 pt of B0 at both reads, or, with
///     B0 off, the same at both within 4 pt); and the reference's rise equals the last row's growth (its frame's
///     height at the second read less at the first) within 4 pt. The growth is measured inside one row, so a move of
///     the whole page leaves it unchanged while it moves the reference: their difference is everything that isn't the
///     stream. All four hold: a lead-in, "(by growth; ...)" with its numbers, counted with the others toward the 3
///     before a VOID. Checked and declined: "MARK P growth drag <k>: measured (<the condition that failed>; ...)".
///     The decision is T729StreamMatch.decide, at the end of this file, pure, with a desk table of its own.
///   - the pre-finger read: just before every measured drag's finger, a fresh read. If the reference moved by itself
///     since the read it was taken from, the same stream match decides, between that read and this one: a lead-in
///     there means the drag is measured from this read. Any other move, or the reference gone: measured from the
///     earlier read, as v6. Either way "MARK P v7 pre-read drag <k>: ..." says which, with the numbers. A move under
///     1 pt says nothing.
/// - v7: T729_OPEN_WAIT (s, 0.5 to 3, default 3): the wait at the end after the open, as v6's 3 s; shorter only for
///   validation. The SETUP line prints it on every run. It lives in this test only.
/// - v8, streaming on with B0 on only (B0 off: v7 as is), two rules, for a reply that fills the window alone:
///   - by growth, the end only: when v6 and v7's growth match both decline, the same two reads once more. It applies
///     only when no keyed row other than the last is wholly in the window at both reads (there, v7's match decides).
///     The last row's bottom is within 8 pt of B0 at both reads and inside the window; its top may be clipped by the
///     window; and it grew by 1 pt or more (its frame's height at the second read less the first). Any other keyed row
///     in the window at both reads, in part, must have risen by the growth within 4 pt. All hold: a lead-in, "(by
///     growth, the end only; ...)" with every number read. Declined: the "MARK P growth drag" line gives both reasons.
///   - the pre-read: when the reference moved 1 pt or more since its read, or is gone, v7's match and then the end only
///     decide on the read the reference came from and the pre-read. Either says lead-in: the drag is a lead-in,
///     unmeasured, "(by the pre-read; the v7 match|the end only; ...)". This replaces v7's "measured from the
///     pre-finger read". Anything else is measured from the earlier read, as v7, and its line gives both reasons.
///   Both count toward the 3 lead-ins before a VOID. Both decisions are T729StreamMatch.either, pure, at the end of
///   this file. History drags are untouched.
///   The scroll offset can't be read here: each read is one accessibility snapshot of row frames, with no offset, and
///   exposing one would be an app change. So the end-only rule doesn't check the offset's change against the growth;
///   the after-run frame look on every drag it excuses carries that check (the app's GEO lines have the offset).
/// The test goes on to the top and fails at the end with every JUMP named. The top is reached when the spinner row
/// (`thread.older`) is gone and a drag no longer moves the reference. 64 has no spinner row, so its top is the drag that
/// moves nothing.
/// Nothing is set: no orientation, look or text size. The window is read only.
@MainActor
final class ThreadPagingUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private let perf = Logger(subsystem: "Vory", category: "perf")

    /// One line to the test's log and the same line to the perf log, beside the app's own GEO and PAGE lines.
    private func say(_ s: String) {
        print("T729P \(s)")
        perf.notice("T729P \(s, privacy: .public)")
    }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func f(_ r: CGRect) -> String { String(format: "(%.1f,%.1f,%.1f,%.1f)", r.minX, r.minY, r.width, r.height) }
    private func number(_ key: String, _ fallback: Double, _ low: Double, _ high: Double) -> Double {
        guard let v = env[key].flatMap(Double.init), v >= low, v <= high else { return fallback }
        return v
    }
    private var chat: String { env["T729_CHAT"].flatMap { $0.isEmpty ? nil : $0 } ?? "Disk cleanup on the log host" }
    private var dragPt: Double { number("T729_DRAG", 300, 100, 500) }
    private var rest: Double { number("T729_REST", 1.5, 0.5, 5) }
    private var maxDrags: Int { Int(number("T729_DRAGS", 400, 10, 600)) }
    /// v2: streaming on (tall3w) when T729_STREAMING is set and not "0"; then the last row is never the reference.
    private var streaming: Bool { let s = env["T729_STREAMING"] ?? ""; return !s.isEmpty && s != "0" }
    /// v2: the most lead-in drags (streaming on, only the last row in the window) before a VOID.
    private let maxLeadIns = 3
    /// v4: the mode (slow, reopen or fast; anything else is slow).
    private var mode: String { let m = env["T729_MODE"] ?? ""; return (m == "reopen" || m == "fast") ? m : "slow" }
    /// v4: the flings in fast mode, and their settle limit and still check.
    private let flings = 6
    private let settleMax: Double = 3
    private let stillRest: Double = 1.5
    /// The touch's slop: a slow drag of 300 pt moved the thread 290 pt in every still leg of #729's runs.
    private let slop: Double = 10
    /// How far the reference may land from where the drag should have put it.
    private let tolerance: Double = 40
    /// v6: the stuck-to-the-end lead-in (streaming on only): the position band around B0, the follow's limit (the guard)
    /// and the gap between the two reads.
    private let stuckBand: CGFloat = 8
    private let followMax: CGFloat = 60
    private let followGap: Double = 0.3
    /// v7: the wait at the end after the open (not in fast mode). 3 s unless set from 0.5 to 3, for validation only.
    private var openWait: Double { number("T729_OPEN_WAIT", 3, 0.5, 3) }

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
    /// v4: the thread's back button, as testThread729 finds it.
    private var back: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "chat.back") }

    private func void(_ why: String) {
        say("VOID \(why); window \(f(app.windows.firstMatch.frame))")
        XCTFail("T729P VOID: \(why)")
    }

    /// One reading of the window: every message row's label and frame, and whether the spinner row is there. It's one
    /// snapshot of the app's accessibility tree, not a query per row (a 294-row chat over 150 drags).
    /// v2: each row's key (its own label, else the first 3 labels inside it), its frame, and whether it's the last
    /// `thread.row.` element in the snapshot; `all` counts every `thread.row.` element, keyed or not.
    private struct Reading {
        var rows: [(label: String, frame: CGRect, last: Bool)] = []
        var all = 0
        var spinner = false
    }
    /// v2: a row's key. Its own label if it has one; else the first 3 non-empty labels inside it, depth first, joined
    /// by " | " and cut at 120 characters; else "" (no key).
    private func key(_ n: XCUIElementSnapshot) -> String {
        if !n.label.isEmpty { return String(n.label.prefix(120)) }
        var found: [String] = []
        func inside(_ c: XCUIElementSnapshot) {
            if found.count >= 3 { return }
            if !c.label.isEmpty { found.append(c.label) }
            for d in c.children { inside(d) }
        }
        for c in n.children { inside(c) }
        return String(found.prefix(3).joined(separator: " | ").prefix(120))
    }
    private func read() -> Reading {
        var out = Reading()
        guard let s = try? app.snapshot() else { return out }
        var lastAt = -1
        func walk(_ n: XCUIElementSnapshot) {
            if n.identifier.hasPrefix("thread.row.") {
                out.all += 1
                let k = key(n)
                lastAt = k.isEmpty ? -1 : out.rows.count
                if !k.isEmpty { out.rows.append((k, n.frame, false)) }
            }
            if n.identifier == "thread.older" { out.spinner = true }
            for c in n.children { walk(c) }
        }
        walk(s)
        // The last `thread.row.` element in the snapshot, if it has a key (an unkeyed last row is never the reference).
        if lastAt >= 0 { out.rows[lastAt].last = true }
        return out
    }

    /// The row the reader is on: the keyed row whose frame holds the window's middle, else the nearest to it. v2: with
    /// `skipLast`, the last row in the snapshot is never taken.
    private func reference(_ r: Reading, in window: CGRect, skipLast: Bool) -> (label: String, frame: CGRect)? {
        let middle = window.midY
        var best: (label: String, frame: CGRect, gap: CGFloat)?
        for row in r.rows {
            let fr = row.frame
            guard !row.label.isEmpty, fr.height > 0, fr.maxY > window.minY, fr.minY < window.maxY else { continue }
            if skipLast && row.last { continue }
            let gap: CGFloat = (fr.minY <= middle && middle < fr.maxY) ? 0 : min(abs(fr.minY - middle), abs(fr.maxY - middle))
            if best == nil || gap < best!.gap { best = (row.label, fr, gap) }
        }
        return best.map { ($0.label, $0.frame) }
    }

    /// v6: the last row's frame, when it is in the window (any part of it).
    private func lastRow(_ r: Reading, in window: CGRect) -> CGRect? {
        guard let row = r.rows.first(where: { $0.last }) else { return nil }
        let fr = row.frame
        return (fr.height > 0 && fr.maxY > window.minY && fr.minY < window.maxY) ? fr : nil
    }

    /// v8: the keyed rows other than the last, for T729StreamMatch.
    private func others(_ r: Reading) -> [T729StreamMatch.Row] {
        r.rows.filter { !$0.last }.map { T729StreamMatch.Row(label: $0.label, frame: $0.frame) }
    }

    /// The copy of `label` nearest `expectedMinY`, if one is in the window.
    private func find(_ label: String, near expectedMinY: CGFloat, in r: Reading, window: CGRect) -> CGRect? {
        r.rows.filter { $0.label == label && $0.frame.height > 0 && $0.frame.maxY > window.minY && $0.frame.minY < window.maxY }
            .map(\.frame)
            .min { abs($0.minY - expectedMinY) < abs($1.minY - expectedMinY) }
    }

    private func drag(_ k: Int) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = start.withOffset(CGVector(dx: 0, dy: dragPt))
        say("MARK P drag \(k) begin")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        say("MARK P drag \(k) end")
    }
    /// v4: an unmeasured slow drag of a prior open (reopen mode); its marks never read as a measured drag's.
    private func priorDrag(_ leg: String, _ k: Int) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = start.withOffset(CGVector(dx: 0, dy: dragPt))
        say("MARK P prior\(leg) drag \(k) begin")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        say("MARK P prior\(leg) drag \(k) end")
    }
    /// v4: a fling (fast mode): the fast velocity and no hold before the lift, so the thread glides on after it.
    private func fling(_ k: Int) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = start.withOffset(CGVector(dx: 0, dy: dragPt))
        say("MARK P fling \(k) begin")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        say("MARK P fling \(k) end")
    }
    /// v4: the chat opened from the list; true once a row of it exists.
    private func openChat(_ leg: String) -> Bool {
        guard let r = hittable(listRow, timeout: 20) else { void("\(leg): the chat '\(chat)' isn't in the list"); return false }
        say("MARK P open\(leg.isEmpty ? "" : " " + leg)")
        r.tap()
        guard rows.firstMatch.waitForExistence(timeout: 20) else { void("\(leg): the chat showed no row in 20 s"); return false }
        return true
    }
    /// v4: back to the list (reopen mode).
    private func goBack(_ leg: String) -> Bool {
        guard let b = hittable(back, timeout: 10) else { void("\(leg): no back button"); return false }
        b.tap()
        say("MARK P back \(leg)")
        pause(1)
        return true
    }

    func testScrollUpHoldsPlace() throws {
        guard let url = env["HERMES_E2E_URL"], let token = env["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        guard let bundle = env["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { XCTFail("T729P VOID: HERMES_E2E_BUNDLE not set"); return }
        app = XCUIApplication(bundleIdentifier: bundle)
        // As testThread729 launches: the mock as the gateway, on the chat list, no chat restored, the GEO and PAGE lines.
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-restore.openChat", "none", "-vory-geometry-log"]
        app.launch()
        let window = app.windows.firstMatch.frame
        say("SETUP launched; window \(f(window)); drag \(Int(dragPt)) pt, rest \(rest) s, at most \(maxDrags) drags; streaming \(env["T729_STREAMING"] ?? "no"); mode \(mode); open wait \(openWait) s")

        // v4: reopen mode's two prior opens (testThread729's legs A and B), unmeasured.
        if mode == "reopen" {
            guard openChat("A") else { return }
            for k in 1...6 { priorDrag("A", k); pause(0.2) }
            pause(1)
            guard goBack("A") else { return }
            guard openChat("B") else { return }
            pause(1)
            for k in 1...6 { priorDrag("B", k); pause(0.2) }
            pause(1)
            guard goBack("B") else { return }
        }
        guard openChat("") else { return }
        // v4: fast mode starts at once; the others wait 3 s at the end, as v3. v7: openWait, 3 s unless set.
        if mode != "fast" { pause(openWait) }
        // v2: the first reading, before the start line, so the line says what the test read.
        var last = read()
        // v6: the stuck bottom B0 (streaming on only): the last row's frame bottom now, when it is in the window and lies
        // from two thirds of the window's height to its bottom; else the position test is off for the run.
        var b0: CGFloat?
        var b0Note = ""
        if streaming {
            if let lr = lastRow(last, in: window) {
                let low = window.minY + window.height * 2 / 3
                if lr.maxY >= low && lr.maxY <= window.maxY {
                    b0 = lr.maxY
                    b0Note = "; stuck bottom \(Int(lr.maxY)) (the last row's bottom)"
                } else {
                    b0Note = "; stuck bottom off (the last row's bottom \(Int(lr.maxY)) is outside \(Int(low)) to \(Int(window.maxY)))"
                }
            } else {
                b0Note = "; stuck bottom off (the last row isn't in the window)"
            }
        }
        say("MARK P start; rows \(last.all), keyed \(last.rows.count)\(b0Note)")

        var jumps: [String] = []
        // v4: fast mode's flings, each with its settle and still check, before the measured drags.
        if mode == "fast" {
            for g in 1...flings {
                fling(g)
                // The settle: two reads 0.5 s apart with the reference moved under 1 pt; settleMax at most.
                var prev = read()
                var ref = reference(prev, in: window, skipLast: streaming)
                var waited = 0.0
                var settled = false
                var lastMove = 0.0
                while waited < settleMax {
                    pause(0.5); waited += 0.5
                    let now = read()
                    if let r = ref, let at = find(r.label, near: r.frame.minY, in: now, window: window) {
                        lastMove = Double(at.minY - r.frame.minY)
                        if abs(lastMove) < 1 { settled = true; prev = now; break }
                    }
                    prev = now
                    ref = reference(now, in: window, skipLast: streaming)
                }
                if !settled {
                    jumps.append("fling \(g): did not settle in \(Int(settleMax)) s")
                    say("JUMP unsettled fling \(g): \(Int(lastMove)) pt in the last 0.5 s (did not settle in \(Int(settleMax)) s)")
                    continue
                }
                // The still check: no finger, stillRest more, and the reference holds within the tolerance.
                guard let s0 = reference(prev, in: window, skipLast: streaming) else {
                    say("MARK P still fling \(g): no keyed row to hold")
                    continue
                }
                pause(stillRest)
                let after = read()
                if let at = find(s0.label, near: s0.frame.minY, in: after, window: window) {
                    let d = at.minY - s0.frame.minY
                    if abs(d) > tolerance {
                        jumps.append("fling \(g): drift \(Int(d)) pt")
                        say("JUMP drift fling \(g): \(Int(d)) pt (the reference from \(Int(s0.frame.minY)) to \(Int(at.minY)), no finger)")
                    } else {
                        say("MARK P still fling \(g): held (\(Int(d)) pt)")
                    }
                } else {
                    jumps.append("fling \(g): drift, the row at \(Int(s0.frame.minY)) gone")
                    say("JUMP drift fling \(g): the reference row was gone from the window after the rest (was at \(Int(s0.frame.minY)))")
                }
            }
            last = read()
        }
        var still = 0
        var reachedTop = false
        // A short step: the reference moved less than the drag (by more than the tolerance), with no spinner row. That is
        // the last approach to the top when less than a drag's worth of rows was left above, or a jump that fell short.
        // The next drag decides: one that moves nothing (under 1 pt) with no spinner row is the top, and the short step
        // was its approach; one that moves again makes it a JUMP. With the spinner row shown, a short step is a JUMP at
        // once, since older rows were left above it.
        var pending: String?
        func flush(_ why: String) {
            guard let p = pending else { return }
            jumps.append(p)
            say("JUMP offset \(p) (\(why))")
            pending = nil
        }
        var leadIns = 0
        for k in 1...maxDrags {
            guard let ref = reference(last, in: window, skipLast: streaming) else {
                // v2: streaming on, and the only keyed row in the window is the last one: a lead-in drag, unmeasured.
                if streaming, reference(last, in: window, skipLast: false) != nil {
                    leadIns += 1
                    guard leadIns <= maxLeadIns else { void("only the last row in the window after \(maxLeadIns) lead-in drags"); return }
                    say("MARK P lead-in drag \(k): only the last row in the window")
                    drag(k)
                    pause(rest)
                    last = read()
                    continue
                }
                void("no keyed row in the window before drag \(k)"); return
            }
            // v6: streaming on, the last row in the window: is the thread stuck to the end with the reply streaming?
            // Either test decides; the guard keeps any other move of the reference between the reads in this drag's
            // measure, from the first read, as in v4.
            if streaming, let lr = lastRow(last, in: window) {
                let byPosition = b0.map { abs(lr.maxY - $0) <= stuckBand } ?? false
                pause(followGap)
                let second = read()
                let moved: CGFloat? = find(ref.label, near: ref.frame.minY, in: second, window: window).map { $0.minY - ref.frame.minY }
                // v7: by growth, from the same two reads, checked when v6's tests below don't excuse the drag. v8: then
                // by growth, the end only (with B0 on); either one excuses it.
                let growth = T729StreamMatch.either(b0: b0, lastBefore: lr, lastAfter: lastRow(second, in: window),
                                                    refMove: moved, othersBefore: others(last), othersAfter: others(second),
                                                    window: window)
                let guardHolds = moved.map { $0 <= 1 && $0 >= -followMax } ?? false
                // The follow counts only at the end: the last row's bottom within followMax of B0, or, with B0 off, in
                // the window's lower third.
                let atEnd = b0.map { abs(lr.maxY - $0) <= followMax }
                    ?? (lr.maxY >= window.minY + window.height * 2 / 3 && lr.maxY <= window.maxY)
                let byFollow = atEnd && (moved.map { $0 <= -1 && $0 >= -followMax } ?? false)
                if guardHolds && (byPosition || byFollow) {
                    leadIns += 1
                    guard leadIns <= maxLeadIns else { void("stuck to the end after \(maxLeadIns) lead-in drags"); return }
                    let by = byPosition && byFollow ? "both" : (byPosition ? "position" : "follow")
                    say("MARK P lead-in drag \(k): stuck to the end with a reply streaming (by \(by); the last row's bottom \(Int(lr.maxY)), stuck bottom \(b0.map { String(Int($0)) } ?? "off"); the reference moved \(Int(moved ?? 0)) pt in \(followGap) s)")
                    drag(k)
                    pause(rest)
                    last = read()
                    continue
                }
                if growth.leadIn {
                    leadIns += 1
                    guard leadIns <= maxLeadIns else { void("stuck to the end after \(maxLeadIns) lead-in drags"); return }
                    let by = growth.by == T729StreamMatch.byEnd
                        ? "by growth, the end only; \(growth.endOnly.numbers)" : "by growth; \(growth.v7.numbers)"
                    say("MARK P lead-in drag \(k): stuck to the end with a reply streaming (\(by))")
                    drag(k)
                    pause(rest)
                    last = read()
                    continue
                }
                say("MARK P growth drag \(k): measured (\(growth.v7.why); \(growth.v7.numbers); the end only: \(growth.endOnly.why); \(growth.endOnly.numbers))")
            }
            // v7: the pre-finger read (streaming on only). A move of the reference by itself since its read is excused
            // only when the stream match says the rise is the reply's growth (the read it came from and this one): the
            // drag is measured from this read. Anything else is measured from the earlier read, as v6, so the move
            // counts in the drag. A move under 1 pt says nothing.
            // v8, with B0 on: the same move is decided by both matches (v7's, then the end only) on the read the
            // reference came from and this one; either says lead-in: this drag is a lead-in, unmeasured. Anything else
            // is measured from the earlier read. B0 off: v7 as is.
            var origin = ref.frame
            if streaming {
                let pre = read()
                let p = find(ref.label, near: ref.frame.minY, in: pre, window: window)
                let d = p.map { $0.minY - ref.frame.minY }
                if b0 != nil, d == nil || abs(d!) >= 1 {
                    let m = T729StreamMatch.either(b0: b0, lastBefore: lastRow(last, in: window), lastAfter: lastRow(pre, in: window),
                                                   refMove: d, othersBefore: others(last), othersAfter: others(pre), window: window)
                    if m.leadIn {
                        leadIns += 1
                        guard leadIns <= maxLeadIns else { void("stuck to the end after \(maxLeadIns) lead-in drags"); return }
                        let numbers = m.by == T729StreamMatch.byEnd ? m.endOnly.numbers : m.v7.numbers
                        say("MARK P lead-in drag \(k): stuck to the end with a reply streaming (by the pre-read; \(m.by); \(numbers))")
                        drag(k)
                        pause(rest)
                        last = read()
                        continue
                    }
                    say("MARK P v7 pre-read drag \(k): measured from the earlier read (\(m.v7.why); \(m.v7.numbers); the end only: \(m.endOnly.why); \(m.endOnly.numbers))")
                } else if d == nil || abs(d!) >= 1 {
                    let m = T729StreamMatch.decide(b0: b0, lastBefore: lastRow(last, in: window), lastAfter: lastRow(pre, in: window),
                                                   refMove: d, window: window)
                    if m.leadIn, let p {
                        origin = p
                        say("MARK P v7 pre-read drag \(k): measured from the pre-finger read (the stream match; from \(Int(ref.frame.minY)) to \(Int(p.minY)); \(m.numbers))")
                    } else {
                        say("MARK P v7 pre-read drag \(k): measured from the earlier read (\(m.why); \(m.numbers))")
                    }
                }
            }
            drag(k)
            // v4: the early read, just after the lift, beside the late one after the rest.
            let early = read()
            pause(rest)
            let now = read()
            last = now
            let expected = origin.minY + (dragPt - slop)
            guard let at = find(ref.label, near: expected, in: now, window: window) else {
                flush("a drag after it moved the thread")
                jumps.append("drag \(k): the row at \(Int(origin.minY)) left the window")
                say("JUMP left drag \(k): the reference row left the window (was at \(Int(origin.minY)), wanted \(Int(expected)))")
                continue
            }
            let moved = at.minY - origin.minY
            let off = at.minY - expected
            if abs(moved) < 1 {
                // A drag that moved nothing: the top, once nothing is left to reveal.
                if !now.spinner {
                    if pending != nil {
                        say("MARK P top: drag \(k) moved nothing after the short step (\(pending!)): the step was the last approach")
                        pending = nil
                        reachedTop = true
                        break
                    }
                    still += 1
                    say("MARK P top? drag \(k): the reference stayed at \(Int(at.minY)) (\(still) in a row)")
                    if still >= 2 { reachedTop = true; break }
                    continue
                }
                flush("the spinner row still shown")
                jumps.append("drag \(k): moved nothing with older rows left")
                say("JUMP offset drag \(k): moved nothing (the reference at \(Int(at.minY))) with the spinner row shown")
            } else if abs(off) <= tolerance {
                // A drag's move: a short step before it was a JUMP.
                flush("the next drag moved the thread by \(Int(moved)) pt")
                still = 0
                // v4: the late read holds, but the early one was off the drag's place by more than the tolerance, or
                // didn't find the row: a marker for the video, never a JUMP by itself.
                if let e = find(ref.label, near: expected, in: early, window: window) {
                    let eo = e.minY - expected
                    if abs(eo) > tolerance { say("MARK P transient drag \(k): early \(Int(eo)) pt, late \(Int(off)) pt") }
                } else {
                    say("MARK P transient drag \(k): early not in the window, late \(Int(off)) pt")
                }
            } else if off < -tolerance, moved > 0 {
                // A short step: held, or a JUMP at once with the spinner row shown.
                flush("a second short step")
                let step = "drag \(k): \(Int(off)) pt (moved \(Int(moved)) of \(Int(dragPt - slop)))"
                if now.spinner {
                    jumps.append(step)
                    say("JUMP offset \(step) (the spinner row shown)")
                } else {
                    pending = step
                    say("MARK P short \(step): held until the next drag")
                }
            } else {
                // Moved the wrong way, or past the drag: a JUMP.
                flush("a drag after it moved the thread")
                jumps.append("drag \(k): \(Int(off)) pt")
                say("JUMP offset drag \(k): \(Int(off)) pt (the reference at \(Int(at.minY)), wanted \(Int(expected)))")
            }
            say("MARK P rest \(k) end; spinner \(now.spinner ? "shown" : "gone")")
        }
        flush("the last drag")
        say("DONE: \(jumps.count) jump(s); top \(reachedTop ? "reached" : "not reached"); window \(f(app.windows.firstMatch.frame))")
        XCTAssertTrue(jumps.isEmpty, "T729P JUMP: \(jumps.joined(separator: "; "))")
        XCTAssertTrue(reachedTop, "T729P: the top wasn't reached in \(maxDrags) drags")
        XCTAssertFalse(last.spinner, "T729P: older rows are still left at the top")
    }
}

// BEGIN T729StreamMatch (v7 and v8; pure, Foundation and CoreGraphics only: the desk table compiles this block alone)
/// v7: the stuck-to-the-end lead-in by growth. From two reads of the window, is the reference's rise the streaming
/// reply's growth and nothing else? The last row's growth is its own frame's height change, which a move of the whole
/// page leaves unchanged, while the rise is the page's move plus every height change below the reference. So the
/// difference (rise less growth) is the page's own move plus any height change between the two rows: the rise is
/// the stream only when it is under `match`. Any condition that fails means the drag is measured.
enum T729StreamMatch {
    /// The rise must equal the growth within this (pt).
    static let match: CGFloat = 4
    /// The last row's bottom must lie within this of B0 at both reads (pt); v6's stuck band.
    static let pin: CGFloat = 8

    struct Result {
        var leadIn: Bool
        /// The condition that failed ("" when it's a lead-in).
        var why: String
        /// Every number the decision read, for the log line.
        var numbers: String
    }

    static func n(_ v: CGFloat?) -> String { v.map { String(format: "%.1f", Double($0)) } ?? "none" }

    /// - b0: the stuck bottom, nil when the position test is off for the run.
    /// - lastBefore, lastAfter: the last row's frame at the first and second reads, nil when not in the window.
    /// - refMove: the reference's minY at the second read less at the first, nil when it isn't in the window then.
    static func decide(b0: CGFloat?, lastBefore: CGRect?, lastAfter: CGRect?, refMove: CGFloat?, window: CGRect) -> Result {
        let rise = refMove.map { -$0 }
        let growth: CGFloat? = (lastBefore != nil && lastAfter != nil) ? lastAfter!.height - lastBefore!.height : nil
        let diff: CGFloat? = (rise != nil && growth != nil) ? rise! - growth! : nil
        let numbers = "rise \(n(rise)), growth \(n(growth)), difference \(n(diff)), bottoms \(n(lastBefore?.maxY)) and "
            + "\(n(lastAfter?.maxY)) against \(b0.map { n($0) } ?? "off"), the reference \(refMove == nil ? "gone" : "in the window")"
        func no(_ why: String) -> Result { Result(leadIn: false, why: why, numbers: numbers) }
        guard let rise else { return no("the reference not in the window at the second read") }
        guard rise >= 1 else { return no(rise <= -1 ? "the reference fell" : "no rise") }
        guard let a = lastBefore, let b = lastAfter else { return no("the last row not in the window at both reads") }
        guard a.minY >= window.minY, a.maxY <= window.maxY, b.minY >= window.minY, b.maxY <= window.maxY else {
            return no("the last row clipped by the window")
        }
        let pinned = b0.map { abs(a.maxY - $0) <= pin && abs(b.maxY - $0) <= pin } ?? (abs(b.maxY - a.maxY) <= match)
        guard pinned else { return no("the end not pinned") }
        guard let diff, abs(diff) <= match else { return no("the rise doesn't match the growth") }
        return Result(leadIn: true, why: "", numbers: numbers)
    }

    /// v8: a keyed row other than the last, as one read saw it: its key and its frame.
    struct Row {
        var label: String
        var frame: CGRect
    }

    /// v8, by growth, the end only: for a reply that fills the window alone, so there's no row above it to match. It
    /// applies only when no keyed row other than the last is wholly in the window at both reads (there, v7's match
    /// decides). The last row's bottom lies within `pin` of B0 at both reads and inside the window (its top may be
    /// clipped), and its frame grew by 1 pt or more. Any other keyed row in the window at both reads, in part, must have
    /// risen by the growth within `match`: while the end is pinned, every row above the reply rises by its growth, so
    /// a row that doesn't is a move of the page. B0 off: never. Any condition that fails means the drag is measured.
    /// - othersBefore, othersAfter: the keyed rows other than the last at each read. A row at both reads is paired by
    ///   its key (the fixture's repeats lie thousands of points apart, so one window holds one copy).
    static func endOnly(b0: CGFloat?, lastBefore: CGRect?, lastAfter: CGRect?, othersBefore: [Row], othersAfter: [Row],
                        window: CGRect) -> Result {
        func inWindow(_ r: CGRect) -> Bool { r.height > 0 && r.maxY > window.minY && r.minY < window.maxY }
        func wholly(_ r: CGRect) -> Bool { r.height > 0 && r.minY >= window.minY && r.maxY <= window.maxY }
        let growth: CGFloat? = (lastBefore != nil && lastAfter != nil) ? lastAfter!.height - lastBefore!.height : nil
        // The other rows in the window at both reads: each one's rise, and whether it was wholly in the window at both.
        var both: [(rise: CGFloat, wholly: Bool)] = []
        for a in othersBefore where inWindow(a.frame) {
            let copies = othersAfter.filter { $0.label == a.label && inWindow($0.frame) }
            guard let b = copies.min(by: { abs($0.frame.minY - a.frame.minY) < abs($1.frame.minY - a.frame.minY) }) else { continue }
            both.append((a.frame.minY - b.frame.minY, wholly(a.frame) && wholly(b.frame)))
        }
        let whole = both.filter { $0.wholly }.count
        let worst: CGFloat? = growth.flatMap { g in both.map { abs($0.rise - g) }.max() }
        let numbers = "growth \(n(growth)), bottoms \(n(lastBefore?.maxY)) and \(n(lastAfter?.maxY)) against "
            + "\(b0.map { n($0) } ?? "off"), tops \(n(lastBefore?.minY)) and \(n(lastAfter?.minY)), other rows wholly in the "
            + "window at both reads \(whole), in it at both reads \(both.count), their largest difference from the growth \(n(worst))"
        func no(_ why: String) -> Result { Result(leadIn: false, why: why, numbers: numbers) }
        guard let b0 else { return no("B0 off") }
        guard let a = lastBefore, let b = lastAfter, let growth else { return no("the last row not in the window at both reads") }
        guard whole == 0 else { return no("another row wholly in the window at both reads") }
        guard a.maxY <= window.maxY, b.maxY <= window.maxY else { return no("the last row's bottom out of the window") }
        guard abs(a.maxY - b0) <= pin, abs(b.maxY - b0) <= pin else { return no("the end not pinned") }
        guard growth >= 1 else { return no("no growth") }
        if let worst, worst > match { return no("another row's rise doesn't match the growth") }
        return Result(leadIn: true, why: "", numbers: numbers)
    }

    /// v8: which match excused the drag.
    static let byV7 = "the v7 match"
    static let byEnd = "the end only"

    /// v8: both matches on one pair of reads, in order: v7's, then the end only. A lead-in when either says so; `by`
    /// names the one that did ("" when neither), and both results are kept for the log.
    struct Both {
        var leadIn: Bool
        var by: String
        var v7: Result
        var endOnly: Result
    }

    static func either(b0: CGFloat?, lastBefore: CGRect?, lastAfter: CGRect?, refMove: CGFloat?, othersBefore: [Row],
                       othersAfter: [Row], window: CGRect) -> Both {
        let v7 = decide(b0: b0, lastBefore: lastBefore, lastAfter: lastAfter, refMove: refMove, window: window)
        let end = endOnly(b0: b0, lastBefore: lastBefore, lastAfter: lastAfter, othersBefore: othersBefore,
                          othersAfter: othersAfter, window: window)
        let by = v7.leadIn ? byV7 : (end.leadIn ? byEnd : "")
        return Both(leadIn: !by.isEmpty, by: by, v7: v7, endOnly: end)
    }
}
// END T729StreamMatch
