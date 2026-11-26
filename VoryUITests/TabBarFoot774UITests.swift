import UIKit
import XCTest

/// The floating tab bar's foot. Along the bottom, the capsule and its circles hang past the bar's layout frame into the
/// home-indicator area, as the system's own bar does. This reads a still of the screen, at the end of Settings in dark
/// mode, where the page under and beside the bar is plain, and asserts that the bar is drawn down there. Just above and
/// below the Settings tab's lower edge, down the middle of the Settings tab, the voice circle and the compose circle, each
/// row's pixel must differ from the page's pixel in the same row beside the bar. A bar cut flat at its frame leaves those
/// rows plain page, and fails. A bar standing on a side strip is logged and skipped: its ride has its own tests.
///
/// HERMES_E2E_BUNDLE names the demo copy to drive, as the other demo tests take it. Run it with the simulator in dark
/// mode; in light mode the page and the glass are too close to tell apart, and it skips.
@MainActor
final class TabBarFoot774UITests: XCTestCase {
    private var app: XCUIApplication!

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func rect(_ e: XCUIElement) -> String {
        guard e.exists else { return "absent" }
        let f = e.frame
        return String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY, f.width, f.height)
    }

    /// A still's pixels, read in points.
    private struct Still {
        let width: Int, height: Int, scale: CGFloat
        let bytes: [UInt8]
        init?(_ image: UIImage) {
            guard let cg = image.cgImage else { return nil }
            // Locals in the closure: it may not capture self before every property is set.
            let w = cg.width, h = cg.height
            var b = [UInt8](repeating: 0, count: w * h * 4)
            let ok = b.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            width = w; height = h; scale = CGFloat(w) / image.size.width
            bytes = b
        }
        /// The luminance at a point, 0 to 1; nil off the image.
        func lum(_ x: CGFloat, _ y: CGFloat) -> Double? {
            let px = Int(x * scale), py = Int(y * scale)
            guard px >= 0, py >= 0, px < width, py < height else { return nil }
            let i = (py * width + px) * 4
            return (0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])) / 255
        }
    }

    func testTheBarIsDrawnDownToItsFoot() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        if let b = env["HERMES_E2E_BUNDLE"], !b.isEmpty { app = XCUIApplication(bundleIdentifier: b) } else { app = XCUIApplication() }
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "settings", "-restore.openChat", "none"]
        app.launch()
        let tab = any("tab.settings")
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Settings tab")
        if !any("settings.row.profile").waitForExistence(timeout: 5) { tab.tap() }
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 20), "Settings didn't open")
        pause(1.0)
        // The end of the list: slow drags, held before the finger lifts, until the rows stop moving.
        let w = app.windows.firstMatch
        var last = ""
        for _ in 0..<14 {
            let start = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -min(400, w.frame.height * 0.4))),
                        withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.5)
            pause(0.8)
            let now = rect(any("settings.row.profile")) + rect(app.cells.allElementsBoundByIndex.last ?? tab)
            if now == last { break }
            last = now
        }
        pause(1.0)
        let win = w.frame, t = tab.frame
        let voice = any("chats.voice"), compose = any("chats.new")
        print("FOOT774 frames window \(rect(w)) tab.settings \(rect(tab)) chats.voice \(rect(voice)) chats.new \(rect(compose))")
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = "foot774"; a.lifetime = .keepAlways; add(a)
        // Along the bottom: the Settings tab stands in the window's lowest part.
        guard t.midY > win.height * 0.7 else {
            print("FOOT774 the bar isn't along the bottom (tab.settings \(rect(tab))): skipped")
            throw XCTSkip("the bar stands on a side strip")
        }
        guard let still = Still(shot.image) else { return XCTFail("the still's pixels couldn't be read") }
        // The page beside the bar, in each row: 4 pt in from the window's leading edge, outside the bar's margin.
        let refX = win.minX + 4
        guard let pageLum = still.lum(refX, t.maxY), pageLum < 0.2 else {
            print("FOOT774 the page beside the bar isn't dark (\(still.lum(refX, t.maxY) ?? -1)): skipped")
            throw XCTSkip("not dark mode")
        }
        var columns: [(String, CGFloat)] = [("tab.settings", t.midX)]
        if voice.exists { columns.append(("chats.voice", voice.frame.midX)) }
        if compose.exists { columns.append(("chats.new", compose.frame.midX)) }
        let rows = stride(from: t.maxY - 8, through: t.maxY + 2, by: 1).map { $0 }
        var failed: [String] = []
        for (name, x) in columns {
            var drawn = 0
            var line = "FOOT774 \(name) x \(String(format: "%.1f", x)):"
            for y in rows {
                guard let l = still.lum(x, y), let r = still.lum(refX, y) else { line += " off"; continue }
                let d = abs(l - r)
                if d >= 0.03 { drawn += 1 }
                line += String(format: " %.0f:%.3f", y, d)
            }
            print(line + " drawn \(drawn)/\(rows.count)")
            if drawn < rows.count - 2 { failed.append("\(name) \(drawn)/\(rows.count)") }
        }
        XCTAssertTrue(failed.isEmpty, "the bar isn't drawn down to its foot: \(failed.joined(separator: ", "))")
    }
}
