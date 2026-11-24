import Foundation

/// Where a chat's thread starts drawing its rows, as the chat keeps it (`ChatSession.revealFrom`): the first drawn row's
/// id, and how many rows from the end that row was when it was set, for use if that id has gone.
public struct RevealFrom: Equatable, Sendable {
    public let id: String
    public let fromEnd: Int
    public init(id: String, fromEnd: Int) {
        self.id = id
        self.fromEnd = fromEnd
    }
}

/// #729's paging (65): which of a thread's rows are drawn, and which of those are laid plain. Pure. The thread view
/// (`TranscriptView`) gives it counts and indexes into the rows it shows (after its display filter); the page rule
/// (`ThreadPages`) gives the newest page's start.
public enum ThreadWindow {
    /// The most rows laid plain at once (measured, never a lazy stack's guess): the ceiling. Past it, the rows nearest the
    /// tail go lazy. Those are below a reader who is up the thread, where a lazy row's guess can't move what is read.
    /// The SE perf read sets it: a reveal at this many plain rows must take under 50 ms. If it doesn't, the page shrinks
    /// first (`ThreadPages`).
    public static let ceiling = 200

    /// The first drawn row:
    /// - the kept row, if it is still among the rows, but never after the newest page's start;
    /// - else, if its id has gone (a compression, a re-read), the same count of rows from the end it had;
    /// - with nothing kept, the newest page's start.
    /// A snapshot that adds rows at the end leaves a kept row's index as it is, so the rows the reader is on stay drawn
    /// and only the end grows. That is what wins when a snapshot lands during a reveal: the reveal's row stays the start.
    public static func start(count: Int, keptIndex: Int?, keptFromEnd: Int?, newest: Int) -> Int {
        let newest = min(max(0, newest), count)
        if let i = keptIndex, i >= 0, i < count { return min(i, newest) }
        if let n = keptFromEnd, n > 0 { return min(max(0, count - n), newest) }
        return newest
    }

    /// Where the plain rows at the top of the drawn window end. The drawn rows run from `top` to `count`; the tail's plain
    /// rows begin at `tail` (at or after `top`).
    /// - While every drawn row fits the ceiling, they are all plain: the end is `tail`.
    /// - Past the ceiling, the top keeps what the ceiling leaves after the tail, and never less than the last page
    ///   revealed (`lastPage`), so a page is always laid plain as it comes.
    /// The rows from the returned index to `tail` are the lazy middle.
    public static func plainTopEnd(top: Int, tail: Int, count: Int, lastPage: Int, ceiling: Int = ceiling) -> Int {
        guard tail > top else { return top }
        let room = max(0, ceiling - (count - tail))
        return min(tail, top + max(room, lastPage))
    }
}
