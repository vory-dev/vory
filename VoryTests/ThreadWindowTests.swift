import Testing
@testable import VoryCore

/// Which rows a long chat's thread draws (`ThreadWindow`, #729's paging): the start the chat keeps across snapshots, and
/// where the plain rows end under the ceiling.
@Suite struct ThreadWindowTests {
    /// Nothing kept: the newest page.
    @Test func nothingKeptIsTheNewestPage() {
        #expect(ThreadWindow.start(count: 294, keptIndex: nil, keptFromEnd: nil, newest: 252) == 252)
        #expect(ThreadWindow.start(count: 27, keptIndex: nil, keptFromEnd: nil, newest: 0) == 0)
    }

    /// A kept row still among the rows is the start.
    @Test func keptRowIsTheStart() {
        #expect(ThreadWindow.start(count: 294, keptIndex: 120, keptFromEnd: 174, newest: 252) == 120)
    }

    /// A snapshot that lands during a reveal, with new history at the end (a re-attach while the reader is up the
    /// thread): the revealed row keeps its index, so the rows drawn above the reader stay, and only the end grows.
    /// The snapshot's history landing then runs as it does today; the reveal's start is what the drawn rows keep.
    @Test func snapshotDuringARevealKeepsTheRevealedRow() {
        let before = ThreadWindow.start(count: 294, keptIndex: 212, keptFromEnd: 82, newest: 252)
        let after = ThreadWindow.start(count: 324, keptIndex: 212, keptFromEnd: 82, newest: 282)
        #expect(before == 212)
        #expect(after == 212)
    }

    /// The kept row's id gone (a compression, a re-read): the same count of rows from the end it had.
    @Test func keptIdGoneKeepsTheCountFromTheEnd() {
        #expect(ThreadWindow.start(count: 310, keptIndex: nil, keptFromEnd: 200, newest: 268) == 110)
        // More kept than there are rows: from the first row.
        #expect(ThreadWindow.start(count: 150, keptIndex: nil, keptFromEnd: 200, newest: 108) == 0)
    }

    /// Never fewer rows than the newest page: a kept row after its start (rows taken away above) gives the newest page.
    @Test func neverAfterTheNewestPage() {
        #expect(ThreadWindow.start(count: 100, keptIndex: 90, keptFromEnd: 10, newest: 60) == 60)
        #expect(ThreadWindow.start(count: 100, keptIndex: nil, keptFromEnd: 5, newest: 60) == 60)
    }

    /// Every drawn row is plain while they all fit the ceiling.
    @Test func allPlainUnderTheCeiling() {
        #expect(ThreadWindow.plainTopEnd(top: 100, tail: 250, count: 294, lastPage: 40) == 250)
        // No rows above the tail's: nothing at the top.
        #expect(ThreadWindow.plainTopEnd(top: 252, tail: 240, count: 294, lastPage: 40) == 252)
    }

    /// Past the ceiling, the top keeps what the ceiling leaves after the tail, never less than the last page.
    @Test func pastTheCeilingTheTopKeepsTheRest() {
        // 294 drawn, 44 in the tail: the top keeps 156, and the 94 below them are the lazy middle.
        #expect(ThreadWindow.plainTopEnd(top: 0, tail: 250, count: 294, lastPage: 40) == 156)
        // A tail of 190 leaves 10: the last page (40) is laid plain anyway.
        #expect(ThreadWindow.plainTopEnd(top: 0, tail: 104, count: 294, lastPage: 40) == 40)
    }
}
