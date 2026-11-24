import Foundation

/// Where a long chat's loaded rows start, when the thread lays out only its newest rows and shows older ones as the
/// reader scrolls up, from the history the app already holds. Pure: counts and indexes only, so the thread and the
/// tests share one rule.
///
/// Indexes are into the rows the thread shows (after its display settings). `turnStarts` lists, in ascending order,
/// the indexes of the rows that open a turn (the reader's own messages), so a page never cuts a question from its
/// reply.
public enum ThreadPages {
    /// Rows a page holds, before its start moves back to the start of the turn it cuts.
    public static let size = 40
    /// The most rows one page holds: a turn longer than this is cut inside, at its last `cap` rows.
    public static let cap = 96

    /// The first row of the newest page of `count` rows.
    public static func newestPageStart(count: Int, turnStarts: [Int]) -> Int {
        olderPageStart(from: count, turnStarts: turnStarts)
    }

    /// The first row of the page above `top`, the first row loaded now. 0 when the page reaches the history's start.
    public static func olderPageStart(from top: Int, turnStarts: [Int]) -> Int {
        let cut = top - size
        guard cut > 0 else { return 0 }
        // The turn that holds the cut starts at the last turn start at or before it; with none, the history's start.
        let turn = turnStarts.last { $0 <= cut } ?? 0
        return max(turn, top - cap)
    }

    /// True when the loaded rows are too short to open on, so the next page is shown in the same open: less than two
    /// screens tall with older rows left. A chat of short rows then never opens with its reader already where the next
    /// page is asked for.
    public static func needsTopUp(loadedHeight: Double, screenHeight: Double, top: Int) -> Bool {
        top > 0 && screenHeight > 0 && loadedHeight < 2 * screenHeight
    }
}
