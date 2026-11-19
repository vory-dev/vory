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

    /// A, the loop (#729): UIKit kept the taller height (31042, its end 30247) after `now` put the thread at the end of
    /// its reading (18582, from SwiftUI's 19377). The landing keeps `now`'s place ("nowset") instead of pushing it to
    /// UIKit's end, so the next reading doesn't find it past the end again. Before the fix it returned nil (set 30247).
    @Test func theLandingNeverPushesPastNow() {
        #expect(Self.run(from: 18582, uikitH: 31042, set: 18582) == "nowset")
        // 58's own loop: SwiftUI's 60358 against UIKit's 62072, `now` at 59624 and UIKit's end at 61338.
        #expect(LandRule.run(from: 59624, end: 61338, set: 59624, background: false, locked: true, finger: false,
                             idleOrAnimating: true, viewWhy: nil, hold: nil) == "nowset")
    }

    /// A, stepped: four turns of the landing with the two heights apart, a reading's end (18582) and UIKit's (30247),
    /// from past the end. Before the fix each turn went to 18582 and then to 30247, ending past the reading's end, so the
    /// next reading landed it again (every turn read 30247, for as long as the heights stayed apart); with it, it lands
    /// once at 18582 and stays there.
    @Test func steppedTurnsSettleAtTheReadingsEnd() {
        let readingEnd: CGFloat = 18582, uikitEnd: CGFloat = 30247
        var offset: CGFloat = 29045
        var seen: [CGFloat] = []
        for _ in 0..<4 {
            var set: CGFloat?
            // The reading finds the thread past its end only while the offset is past the reading's end.
            if offset > readingEnd + 1 {
                let d = LandRule.now(live: offset, from: offset, end: readingEnd, topInset: 0, finger: false,
                                     idleOrAnimating: true, hold: nil)
                if d.why == nil { offset = d.target; set = d.target }
                if LandRule.run(from: offset, end: uikitEnd, set: set, background: false, locked: true, finger: false,
                                idleOrAnimating: true, viewWhy: nil, hold: nil) == nil { offset = uikitEnd }
            }
            seen.append(offset)
        }
        #expect(seen == [18582, 18582, 18582, 18582])
    }
}
#endif
