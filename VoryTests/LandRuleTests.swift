#if os(iOS)
import CoreGraphics
import Testing
@testable import Vory

/// The past-end landing's two decisions as pure rules (`LandRule`, #729), fed the figures the thread's probe logged on
/// the iPhone: UIKit's end is its height less 795 pt there (the landing's RUN line: uikitH 20817 at end 20022).
@Suite struct LandRuleTests {
    static let gap: CGFloat = 795

    /// `LandBeforeCommit.run` with UIKit's end from its height, the thread locked, no finger, at rest, nothing holding.
    static func run(from: CGFloat, uikitH: CGFloat, set: CGFloat?, background: Bool = false, finger: Bool = false) -> String? {
        LandRule.run(from: from, end: uikitH - gap, set: set, background: background, locked: true, finger: finger,
                     idleOrAnimating: true, viewWhy: nil, hold: nil)
    }

    /// `LandBeforeCommit.now` from a reading taken where UIKit's offset is, no finger, at rest, nothing holding.
    static func now(at offset: CGFloat, readingEnd: CGFloat) -> (target: CGFloat, why: String?) {
        LandRule.now(live: offset, from: offset, end: readingEnd, topInset: 0, finger: false, idleOrAnimating: true, hold: nil)
    }

    /// `now` lands the reading's own end when the thread is past it (61's first open: 29045, its reading's end 18582).
    @Test func nowLandsTheReadingsEnd() {
        let d = Self.now(at: 29045, readingEnd: 18582)
        #expect(d.why == nil)
        #expect(d.target == 18582)
    }

    /// `now` at the reading's end, or short of it: landed, nothing set.
    @Test func nowAtTheEndIsLanded() {
        #expect(Self.now(at: 18582, readingEnd: 18582).why == "landed")
        #expect(Self.now(at: 18000, readingEnd: 18582).why == "landed")
    }

    /// `now` under a finger, or with UIKit's offset moved since the reading: nothing set.
    @Test func nowWaitsForTheFingerAndTheOffset() {
        let finger = LandRule.now(live: 29045, from: 29045, end: 18582, topInset: 0, finger: true, idleOrAnimating: true, hold: nil)
        #expect(finger.why == "finger")
        let moved = LandRule.now(live: 29100, from: 29045, end: 18582, topInset: 0, finger: false, idleOrAnimating: true, hold: nil)
        #expect(moved.why == "offsets")
    }

    /// B: `now` put the thread past UIKit's end (SwiftUI's height the larger: 38471 against UIKit's 20817): the landing
    /// pulls it back to UIKit's end.
    @Test func pastUIKitsEndIsPulledBack() {
        #expect(Self.run(from: 37676, uikitH: 20817, set: 37676) == nil)
    }

    /// C: the logged escape: UIKit's offset at its own end after `now` set 18582: landed.
    @Test func atUIKitsEndIsLanded() {
        #expect(Self.run(from: 20022, uikitH: 20817, set: 18582) == "landed")
    }

    /// D: no `now` this turn (the card hold's landing): past UIKit's end it lands; at or short of it, landed.
    @Test func withoutNowItLandsOnlyPastTheEnd() {
        #expect(Self.run(from: 21000, uikitH: 20817, set: nil) == nil)
        #expect(Self.run(from: 19000, uikitH: 20817, set: nil) == "landed")
    }

    /// E: in the background nothing lands (59's #713), and under a finger nothing lands, each with its own reason.
    @Test func backgroundAndFingerHold() {
        #expect(Self.run(from: 37676, uikitH: 20817, set: 37676, background: true) == "background")
        #expect(Self.run(from: 37676, uikitH: 20817, set: 37676, finger: true) == "finger")
    }
}
#endif
