import XCTest

/// #541: Home in two columns on a wide window held wider than tall (the Duo on its side, an iPad in landscape), you on
/// the left and your bots on the right (`HomeColumns`). Runs in whatever pose and orientation the simulator is in;
/// HERMES_E2E_LANDSCAPE=1 turns an iPad to landscape first (and back after). The demo's own chats and numbers, opened on
/// Home (`-vory-demo`), so nothing needs a gateway. Home's columns come off its DEBUG readout (`-vory-columns-frames`, `home.columns`), when the build has one (the release head's has none). Driven by
/// HERMES_E2E_COLS_CASE:
/// - "fold": nothing on Home stands on the fold. The band is taken from the window (its middle, 20 pt either side: the
///   Duo's fold as it reports it, Apple's margins in it), checked against the readout's where there is one; every element
///   in Home's own page (the smallest scroll view holding its heading: other tabs' pages stay mounted, and the system's
///   bars span the window) is read off one snapshot, and any whose span across the window meets the band is listed. The
///   page scrolls under the band, so only the x range counts. FOLD PASS with none, FOLD FAIL otherwise: today's one
///   column must FAIL (the red run) for a PASS on two to count.
/// - "oracle": what VoiceOver stops on (`-vory-ax-oracle`) on Home's page, in order: each column read whole, the left
///   first (ORDER PASS when no stop in the left column comes after one in the right).
/// - "audit": performAccessibilityAudit on Home, every type: every issue printed, for the run's compare with the release
///   head's in the same pose.
/// - "frames": every element in the app with its frame (digits in labels masked: times and counts move between runs),
///   for the run's compare with the release head's on the same device and pose (today's paths unchanged, within 0.5 pt);
///   HERMES_E2E_EDIT=1 enters Edit Home first, and brings the page back to its top (a tap on the Home tab).
/// - "launch": the launch and a posture cycle, for a recording read frame by frame (Home must stand in two columns from
///   its first frame): prints the launch's time just before it, then asks the script for the book pose and then flat
///   again (HERMES_E2E_SIGNAL_DIR: want-half-1, want-flat-1, each answered with done-..., holding the click's time),
///   three seconds after each. The red run is the same leg on a build without two columns.
/// - "background": a trip to the background and back (Settings brought to the front, three seconds, the app brought back;
///   VOID, and a failure, when the app never left the front, its state printed either way): the two
///   columns are not built again (the readout's `built` count unchanged) and nothing in Home's page has moved (every
///   element, labels' digits masked, within 0.5 pt of where it stood; on the desk, with no page, the whole app's).
///   BG PASS, BG FAIL otherwise.
/// HERMES_E2E_SIZE: default, xxxlarge or ax1. Skipped unless HERMES_E2E_BUNDLE is set.
@MainActor
final class HomeColumnsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func hittable(_ q: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let e = q.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.3)
        } while Date() < end
        return nil
    }

    /// A rect from the readout's part named `key` ("upfold x y w h"), or nil ("none", or no such part).
    private func rect(_ readout: String, _ key: String) -> CGRect? {
        guard let part = readout.split(separator: ";").first(where: { $0.hasPrefix(key + " ") }) else { return nil }
        let n = part.split(separator: " ").dropFirst().compactMap { Double($0) }
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
    }

    /// Home's own page: the smallest scroll view that holds its heading.
    private func homePage() -> XCUIElement? {
        app.scrollViews.containing(.any, identifier: "home.heading").allElementsBoundByIndex
            .filter { $0.exists && $0.frame.width > 0 }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func signal(_ name: String) {
        guard let dir = env["HERMES_E2E_SIGNAL_DIR"], !dir.isEmpty else { return }
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name), contents: Data())
        print("COLS signal \(name)")
    }
    private func waitFor(_ name: String, timeout: TimeInterval = 90) -> Bool {
        guard let dir = env["HERMES_E2E_SIGNAL_DIR"], !dir.isEmpty else { return false }
        let path = (dir as NSString).appendingPathComponent(name), end = Date().addingTimeInterval(timeout)
        while Date() < end { if FileManager.default.fileExists(atPath: path) { return true }; pause(0.2) }
        return false
    }

    func testHomeInTwoColumns() throws {
        guard let bundle = env["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        continueAfterFailure = true
        let colsCase = env["HERMES_E2E_COLS_CASE"] ?? "fold"
        var args = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "dashboard", "-restore.openChat", "none",
                    "-vory-columns-frames", "-colorSchemePreference", "light"]
        if colsCase == "oracle" { args.append("-vory-ax-oracle") }
        switch env["HERMES_E2E_SIZE"] ?? "default" {
        case "xxxlarge": args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        case "ax1": args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        default: break
        }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = args
        let landscape = env["HERMES_E2E_LANDSCAPE"] == "1"
        if landscape { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if landscape { XCUIDevice.shared.orientation = .portrait } }
        if colsCase == "launch" { print("COLS launch at \(String(format: "%.3f", Date().timeIntervalSince1970))") }
        app.launch()
        XCTAssertTrue(any("home.heading").waitForExistence(timeout: 40), "Home isn't in front")
        pause(4)
        if colsCase == "launch" {
            for want in ["half-1", "flat-1"] {
                signal("want-" + want)
                XCTAssertTrue(waitFor("done-" + want), "no \(want) click")
                pause(3)
            }
        }
        if colsCase == "frames", env["HERMES_E2E_EDIT"] == "1" {
            let edit = app.buttons["Edit Home"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 10), "no Edit Home")
            edit.tap()
            pause(1.5)
            try XCTUnwrap(hittable(app.buttons.matching(identifier: "tab.dashboard"), timeout: 10), "no Home tab").tap()
            pause(2)
            print("COLS editing \(app.buttons["Done"].firstMatch.exists)")
        }
        let readout = any("home.columns")
        let label = readout.waitForExistence(timeout: 5) ? readout.label : "none (no readout in this build)"
        print("COLS readout \(label)")
        // Home's own page: on the desk (half open like a laptop) its heading stands over the scroll, and there is none.
        let homePage = self.homePage()
        print("COLS page \(homePage.map { "\($0.frame)" } ?? "none")")
        // The window as the app lays out in it. On the Duo on its side XCTest has given the application's frame upright
        // (669 x 951) while every element's stood in the window's landscape space: a window read taller than wide with
        // Home's page reaching past its width is taken turned.
        var window = app.windows.firstMatch.frame.size
        if window.height > window.width, let page = homePage, page.frame.maxX > window.width + 0.5 {
            window = CGSize(width: window.height, height: window.width)
            print("COLS window read upright, taken turned")
        }
        // The fold as the Duo reports it on its side: the window's middle, 20 pt either side (Apple's margins in it).
        let band: CGRect? = window.width > window.height ? CGRect(x: window.width / 2 - 20, y: 0, width: 40, height: window.height) : nil
        print("COLS window \(window) band \(band.map { "\($0)" } ?? "none (taller than wide)")")
        if let band, let fold = rect(label, "upfold") {
            let agree = abs(fold.minX - band.minX) <= 0.5 && abs(fold.maxX - band.maxX) <= 0.5
            print("COLS band against the readout's fold \(fold): \(agree ? "agree" : "DISAGREE")")
            XCTAssertTrue(agree, "the window's band and the app's fold disagree")
        }

        switch colsCase {
        case "oracle":
            let page = try XCTUnwrap(homePage, "no Home page")
            let o = any("debug.voiceover")
            XCTAssertTrue(o.waitForExistence(timeout: 5), "no oracle")
            // What isn't Home's own but stands on its page, by identifier, for the run's order read to set aside by
            // frame: this build's DEBUG readout and the tab bar's buttons (the oracle's stops carry no identifier).
            for id in ["home.columns", "tab.dashboard", "tab.chats", "tab.bots", "tab.settings", "chats.voice", "chats.new"] {
                for e in app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex where e.exists {
                    print("COLS chrome \(id) \(e.frame)")
                }
            }
            let stops: [(label: String, frame: CGRect)] = ((o.value as? String) ?? "").split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let n = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
                guard n.count == 4 else { return nil }
                return (String(parts[0]), CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
            }.filter { $0.frame.intersects(page.frame) }
            guard let band else { print("COLS oracle \(stops.count) stops on Home: NO BAND"); return }
            var seenRight = false, late: [String] = []
            for s in stops {
                let side = s.frame.maxX <= band.minX ? "left" : s.frame.minX >= band.maxX ? "right" : "across"
                print("COLS oracle stop \(side) '\(s.label.prefix(50))' \(s.frame)")
                if side == "right" { seenRight = true } else if side == "left" && seenRight { late.append(s.label) }
            }
            print("COLS oracle \(stops.count) stops on Home: " + (late.isEmpty ? "ORDER PASS" : "ORDER FAIL (left after right: \(late.prefix(4)))"))
        case "frames":
            func masked(_ t: String) -> String { String(t.prefix(60).map { $0.isNumber ? "#" : $0 }) }
            var n = 0
            func walk(_ e: XCUIElementSnapshot) {
                for child in e.children {
                    n += 1
                    let f = child.frame
                    print(String(format: "COLS frame %d %d '%@' %.2f %.2f %.2f %.2f", n, Int(child.elementType.rawValue), masked(child.label), f.minX, f.minY, f.width, f.height))
                    walk(child)
                }
            }
            walk(try app.snapshot())
            print("COLS frames \(n) elements")
        case "background":
            func built(_ readout: String) -> Int? {
                readout.split(separator: ";").first(where: { $0.hasPrefix("built ") }).flatMap { Int($0.dropFirst(6)) }
            }
            func frames() throws -> [(name: String, frame: CGRect)] {
                func masked(_ t: String) -> String { String(t.prefix(60).map { $0.isNumber ? "#" : $0 }) }
                var out: [(name: String, frame: CGRect)] = []
                func walk(_ e: XCUIElementSnapshot) {
                    for child in e.children { out.append(("\(child.elementType.rawValue) '\(masked(child.label))'", child.frame)); walk(child) }
                }
                // On the desk Home's heading stands over the scroll and there is no page: the whole app is read there.
                if let page = self.homePage() { walk(try page.snapshot()) } else { walk(try app.snapshot()) }
                return out
            }
            print("COLS background scope \(self.homePage() == nil ? "the app (no Home page: the desk)" : "Home's page")")
            let before = try frames(), builtBefore = built(label)
            // Away by Settings brought to the front: on the Duo the Home button can leave the app in front.
            func state(_ s: XCUIApplication.State) -> String {
                switch s {
                case .unknown: "unknown"
                case .notRunning: "notRunning"
                case .runningBackgroundSuspended: "suspended"
                case .runningBackground: "background"
                case .runningForeground: "foreground"
                @unknown default: "other(\(s.rawValue))"
                }
            }
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.activate()
            guard settings.wait(for: .runningForeground, timeout: 15) else {
                let why = "COLS background VOID: Settings did not come to the front (\(state(settings.state)))"
                print(why); XCTFail(why); return
            }
            let left = app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended
            print("COLS background away app=\(state(app.state)) left=\(left)")
            // A trip on which the app never left the front is no trip: nothing can come back out of place.
            guard left else {
                let why = "COLS background VOID: the app did not leave the front (\(state(app.state)))"
                print(why); XCTFail(why); return
            }
            pause(3)
            print("COLS background before the return app=\(state(app.state))")
            app.activate()
            XCTAssertTrue(any("home.heading").waitForExistence(timeout: 20), "Home isn't back")
            pause(2)
            let after = try frames(), builtAfter = built(readout.label)
            print("COLS background built \(builtBefore.map(String.init) ?? "none") then \(builtAfter.map(String.init) ?? "none")")
            var moved = 0
            if before.count != after.count { print("COLS background \(before.count) elements before, \(after.count) after"); moved += 1 }
            for (a, b) in zip(before, after) where a.name != b.name || abs(a.frame.minX - b.frame.minX) > 0.5 || abs(a.frame.minY - b.frame.minY) > 0.5
                || abs(a.frame.width - b.frame.width) > 0.5 || abs(a.frame.height - b.frame.height) > 0.5 {
                moved += 1
                if moved <= 20 { print("COLS background moved \(a.name) \(a.frame) to \(b.name) \(b.frame)") }
            }
            let same = builtBefore != nil && builtBefore == builtAfter
            print("COLS background \(before.count) elements, \(moved) moved, built \(same ? "unchanged" : "AGAIN"): " + (same && moved == 0 ? "BG PASS" : "BG FAIL"))
        case "launch":
            print("COLS launch done")
        case "audit":
            var count = 0
            try app.performAccessibilityAudit { issue in
                let el = issue.element
                print("COLS audit issue '\(issue.compactDescription)' type \(el?.elementType.rawValue ?? 0) id '\(el?.identifier ?? "")' label '\(el?.label.prefix(60) ?? "")' frame \(el?.frame ?? .zero)")
                count += 1
                return true
            }
            print("COLS audit \(count) issues")
        default:
            let page = try XCTUnwrap(homePage, "no Home page")
            guard let band else { print("COLS fold: NO BAND (the window is taller than wide)"); return }
            var all = 0, crossing = 0
            func walk(_ e: XCUIElementSnapshot) {
                for child in e.children {
                    all += 1
                    let f = child.frame
                    if f.width > 0, f.height > 0, f.maxX > band.minX, f.minX < band.maxX {
                        crossing += 1
                        if crossing <= 40 { print("COLS on the fold: type \(child.elementType.rawValue) id '\(child.identifier)' label '\(child.label.prefix(50))' x \(f.minX) to \(f.maxX)") }
                    }
                    walk(child)
                }
            }
            walk(try page.snapshot())
            print("COLS fold \(band): \(all) elements on Home, \(crossing) on the band: " + (crossing == 0 ? "FOLD PASS" : "FOLD FAIL"))
        }
    }
}
