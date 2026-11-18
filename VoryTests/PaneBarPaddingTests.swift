import CoreGraphics
import Testing
@testable import Vory

/// The top bar's row in a pane (61): in Split View on the Duo on its side, Vory's pane has no status over it and almost
/// no safe area at its top, and the row stood 4 pt under the window's edge, about 22 pt over the bar of the app beside
/// it. A pane's row stands at least `paneRowTop` under its top, and the pages' room under the row moves with it. Every
/// whole-screen window keeps its place, and so does an iPad pane under its status bar.
@Suite struct PaneBarPaddingTests {
    /// The padding as the bar works it out from the window (`WindowGeometry.paneSafeTop`).
    private func padding(window: CGSize, screen: CGSize, safeTop: CGFloat, closed: Bool = false) -> CGFloat {
        TopBarRoom.barPadding(closed: closed, paneSafeTop: TopBarRoom.isPane(window: window, screen: screen) ? safeTop : nil)
    }

    @Test func wholeScreenWindowsAreNotPanes() {
        // The phones, an iPad in full screen, and the Duo in each pose fill their screen.
        #expect(!TopBarRoom.isPane(window: CGSize(width: 402, height: 874), screen: CGSize(width: 402, height: 874)))
        #expect(!TopBarRoom.isPane(window: CGSize(width: 375, height: 667), screen: CGSize(width: 375, height: 667)))
        #expect(!TopBarRoom.isPane(window: CGSize(width: 820, height: 1180), screen: CGSize(width: 820, height: 1180)))
        #expect(!TopBarRoom.isPane(window: CGSize(width: 466, height: 678), screen: CGSize(width: 466, height: 678)))
        #expect(!TopBarRoom.isPane(window: CGSize(width: 951, height: 669), screen: CGSize(width: 951, height: 669)))
        #expect(!TopBarRoom.isPane(window: CGSize(width: 669, height: 951), screen: CGSize(width: 669, height: 951)))
        // Nothing measured yet (the Mac's empty geometry, a launch's first frame): not a pane.
        #expect(!TopBarRoom.isPane(window: .zero, screen: .zero))
        #expect(!TopBarRoom.isPane(window: CGSize(width: 469, height: 669), screen: .zero))
    }

    @Test func theGuardedLayoutsKeepTheirPadding() {
        // The full-screen iPhone (17 Pro, SE): 4, as before.
        #expect(padding(window: CGSize(width: 402, height: 874), screen: CGSize(width: 402, height: 874), safeTop: 62) == 4)
        #expect(padding(window: CGSize(width: 375, height: 667), screen: CGSize(width: 375, height: 667), safeTop: 20) == 4)
        // The iPad in full screen: 4.
        #expect(padding(window: CGSize(width: 820, height: 1180), screen: CGSize(width: 820, height: 1180), safeTop: 24) == 4)
        // The iPad in Split View (right or left, half or a third): a pane, but under its 24 pt status bar 4 still
        // reaches past 26, so 4.
        #expect(padding(window: CGSize(width: 410, height: 1180), screen: CGSize(width: 820, height: 1180), safeTop: 24) == 4)
        #expect(padding(window: CGSize(width: 320, height: 1180), screen: CGSize(width: 820, height: 1180), safeTop: 24) == 4)
        // The Duo closed: 11 (#558); on its side and upright: 4.
        #expect(padding(window: CGSize(width: 466, height: 678), screen: CGSize(width: 466, height: 678), safeTop: 0, closed: true) == 11)
        #expect(padding(window: CGSize(width: 951, height: 669), screen: CGSize(width: 951, height: 669), safeTop: 0) == 4)
        #expect(padding(window: CGSize(width: 669, height: 951), screen: CGSize(width: 669, height: 951), safeTop: 0) == 4)
        // Without a pane the two-argument form is the old one.
        #expect(TopBarRoom.barPadding(closed: true, paneSafeTop: nil) == TopBarRoom.barPadding(closed: true))
        #expect(TopBarRoom.barPadding(closed: false, paneSafeTop: nil) == TopBarRoom.barPadding(closed: false))
    }

    @Test func aPaneWithNoStatusOverItStandsItsRowLower() {
        // The Duo on its side in Split View, Vory on the left: a pane about half the 951 pt screen, no safe area at top.
        let pane = padding(window: CGSize(width: 469, height: 669), screen: CGSize(width: 951, height: 669), safeTop: 0)
        #expect(pane == TopBarRoom.paneRowTop)
        #expect(pane == 26)
        // Some safe area at its top: the row's top stays at 26 from the window's top.
        #expect(padding(window: CGSize(width: 469, height: 669), screen: CGSize(width: 951, height: 669), safeTop: 10) == 16)
        // Never less than the 4 it had.
        #expect(padding(window: CGSize(width: 469, height: 669), screen: CGSize(width: 951, height: 669), safeTop: 40) == 4)
    }

    @Test func thePagesRoomMovesWithTheRow() {
        // Beside the strip, a whole screen: the row's bottom (44) + 11 + the 8 pt gap, as before.
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: 44) == 63)
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: 44, paneSafeTop: nil) == 63)
        // In the pane: 44 + 26 + 8, so the page starts 8 pt under the row (the row's bottom at 26 + 44 = 70).
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: 44, paneSafeTop: 0) == 78)
        // No bar, or nothing measured: no room, pane or not.
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: false, rowBottom: 44, paneSafeTop: 0) == 0)
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: 0, paneSafeTop: 0) == 0)
    }
}
