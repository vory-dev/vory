import Testing
@testable import VoryCore

/// The page rule for a long chat shown from its newest rows (`ThreadPages`): page sizes, whole turns, the cap on a long
/// turn, and the top-up on open.
@Suite struct ThreadPagesTests {
    /// Turn starts every `every` rows from 0, as a chat of equal turns.
    static func turns(_ count: Int, every: Int) -> [Int] { Array(stride(from: 0, to: count, by: every)) }

    /// A chat no longer than a page is one page: everything loaded, nothing above.
    @Test func shortChatIsOnePage() {
        #expect(ThreadPages.newestPageStart(count: 0, turnStarts: []) == 0)
        #expect(ThreadPages.newestPageStart(count: 27, turnStarts: Self.turns(27, every: 7)) == 0)
        #expect(ThreadPages.newestPageStart(count: 40, turnStarts: Self.turns(40, every: 7)) == 0)
    }

    /// Every demo chat (at most four exchanges) opens as one page, so the demo and the tour show no spinner.
    @Test func demoChatIsOnePage() {
        #expect(ThreadPages.newestPageStart(count: 27, turnStarts: [0, 7, 14, 20]) == 0)
    }

    /// The cut moves back to the start of the turn it falls in: 300 rows in turns of 7, the cut at 260 is inside the
    /// turn from 259, so the page starts there (41 rows).
    @Test func cutMovesBackToTheTurnsStart() {
        let t = Self.turns(300, every: 7)
        #expect(ThreadPages.newestPageStart(count: 300, turnStarts: t) == 259)
    }

    /// A cut that falls on a turn's start stays there: exactly `size` rows.
    @Test func cutOnATurnStartStays() {
        #expect(ThreadPages.newestPageStart(count: 100, turnStarts: [0, 30, 60, 90]) == 60)
    }

    /// A turn longer than the cap gives its last `cap` rows: a 200-row last turn from row 100 in 300 rows.
    @Test func longTurnIsCappedAtItsEnd() {
        #expect(ThreadPages.newestPageStart(count: 300, turnStarts: [0, 50, 100]) == 300 - ThreadPages.cap)
    }

    /// The next page up continues the same long turn from where the last one stopped, `cap` rows at a time (204, then
    /// 108), and the page after that reaches back to the start of the turn before it (50).
    @Test func longTurnPagesUpByTheCap() {
        let t = [0, 50, 100]
        let first = ThreadPages.newestPageStart(count: 300, turnStarts: t)
        let second = ThreadPages.olderPageStart(from: first, turnStarts: t)
        let third = ThreadPages.olderPageStart(from: second, turnStarts: t)
        #expect(first == 204)
        #expect(second == 108)
        #expect(third == 50)
    }

    /// History with no turn start before the cut (a bot's opening notes): the page starts at the cap from the top.
    @Test func noTurnStartBeforeTheCut() {
        #expect(ThreadPages.newestPageStart(count: 150, turnStarts: [120]) == 150 - ThreadPages.cap)
        #expect(ThreadPages.newestPageStart(count: 60, turnStarts: []) == 0)
    }

    /// Paging up from the newest page reaches row 0 in whole turns, each page moving up, none empty: 294 rows in turns
    /// of 6 are seven pages of 42 (252, 210, 168, 126, 84, 42, 0).
    @Test func pagesReachTheStartInWholeTurns() {
        let t = Self.turns(294, every: 6)
        var top = ThreadPages.newestPageStart(count: 294, turnStarts: t)
        var pages = 1
        while top > 0 {
            let next = ThreadPages.olderPageStart(from: top, turnStarts: t)
            #expect(next < top)
            #expect(next == 0 || t.contains(next))
            #expect(top - next <= ThreadPages.cap)
            top = next; pages += 1
        }
        #expect(pages == 7)
    }

    /// The top-up: under two screens with older rows left asks for the next page; two screens or more, or nothing above,
    /// doesn't.
    @Test func topUpUnderTwoScreens() {
        #expect(ThreadPages.needsTopUp(loadedHeight: 1500, screenHeight: 800, top: 40))
        #expect(!ThreadPages.needsTopUp(loadedHeight: 1600, screenHeight: 800, top: 40))
        #expect(!ThreadPages.needsTopUp(loadedHeight: 300, screenHeight: 800, top: 0))
        #expect(!ThreadPages.needsTopUp(loadedHeight: 300, screenHeight: 0, top: 40))
    }
}
