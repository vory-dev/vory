import CoreGraphics
import Foundation
import Testing
@testable import VoryCore
@testable import Vory

/// Home at a cold launch (#720): from its first frame it stands in its final layout, with its last numbers and chats,
/// and nothing moves when the fold and the load come.
@Suite(.serialized) struct HomeLaunchTests {
    /// The open Duo on its side: the window 951 x 669, the fold up its middle at 455.5 to 495.5.
    private let side = CGSize(width: 951, height: 669)
    private let upFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private var sideRead: ReservedRegions {
        ReservedRegions(divisions: [upFold], upFold: upFold, reported: [.init(kind: .fold, frame: upFold, active: true)])
    }

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let suite = "dev.vory.tests.homelaunch." + UUID().uuidString
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    // MARK: The fold at launch (`HomeLaunchFold`)

    @Test func untilTheRegionsAreReadHomeStandsInTheFoldKeptForTheShape() {
        let unread = ReservedRegions()
        let early = HomeLaunchFold.regions(live: unread, kept: upFold)
        #expect(early.upFold == upFold)
        #expect(HomeTiles.columns(regions: early) == 2, "three to a row until the fold came")
        // Once read, the live regions, whatever was kept.
        #expect(HomeLaunchFold.regions(live: sideRead, kept: CGRect(x: 1, y: 0, width: 40, height: 669)).upFold == upFold)
        // Nothing kept: the live regions, as before (a first launch, a phone, an iPad, the Duo upright or closed).
        #expect(HomeLaunchFold.regions(live: unread, kept: nil).upFold == nil)
        #expect(HomeTiles.columns(regions: HomeLaunchFold.regions(live: unread, kept: nil)) == 3)
    }

    @Test func aReadKeepsTheFoldForTheShapeAndAShapeWithNoneKeepsNothing() throws {
        let (d, suite) = try scratchDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        // Nothing before the regions are read.
        HomeLaunchFold.note(ReservedRegions(), shape: "side", size: side, in: d)
        #expect(d.object(forKey: HomeLaunchFold.storeKey) == nil)
        HomeLaunchFold.note(sideRead, shape: "side", size: side, in: d)
        #expect(HomeLaunchFold.kept(for: "side", in: d) == upFold)
        // The Duo upright: a fold across only, so no fold up it is kept for that shape.
        let across = CGRect(x: 0, y: 456, width: 669, height: 40)
        let upright = ReservedRegions(divisions: [across], reported: [.init(kind: .fold, frame: across, active: true)])
        HomeLaunchFold.note(upright, shape: "upright", size: CGSize(width: 669, height: 951), in: d)
        #expect(HomeLaunchFold.kept(for: "upright", in: d) == nil)
        #expect(HomeLaunchFold.kept(for: "side", in: d) == upFold, "another shape's read took the side's fold")
        // A shape read again with no fold up it any more drops what it kept.
        HomeLaunchFold.note(upright, shape: "side", size: side, in: d)
        #expect(HomeLaunchFold.kept(for: "side", in: d) == nil)
    }

    @Test func aFoldThatDoesNotFitTheWindowIsNotKept() throws {
        let (d, suite) = try scratchDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        // The side's fold read while the window still stood at the upright size remembered from the last launch.
        HomeLaunchFold.note(sideRead, shape: "upright", size: CGSize(width: 669, height: 951), in: d)
        #expect(HomeLaunchFold.kept(for: "upright", in: d) == nil)
        #expect(HomeLaunchFold.fits(upFold, in: side))
        #expect(!HomeLaunchFold.fits(CGRect(x: 0, y: 456, width: 669, height: 40), in: CGSize(width: 669, height: 951)))
        #expect(!HomeLaunchFold.fits(CGRect(x: 960, y: 0, width: 40, height: 669), in: side))
    }

    // MARK: Home's last numbers and chats (`HomeCache`)

    private let list = [StoredSession(id: DemoContent.botChatID, title: "Bot Chat", lastActive: 1, messageCount: 4)]
    private func usage(_ sessions: Int) throws -> UsageAnalytics {
        try JSONDecoder().decode(UsageAnalytics.self, from: Data(#"{"totals":{"totalSessions":\#(sessions)}}"#.utf8))
    }

    @Test func aGatewaysHomeIsKeptAndReadBackByBotRangeAndChatsFrom() throws {
        let (d, suite) = try scratchDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let own = UUID()
        HomeCache.save(sessions: list, connection: own, profile: "default", allBots: false, ephemeral: false, in: d)
        HomeCache.save(usage: try usage(2), connection: own, profile: "default", days: 30, ephemeral: false, in: d)
        #expect(HomeCache.sessions(connection: own, profile: "default", allBots: false, ephemeral: false, in: d)?.map(\.id) == [DemoContent.botChatID])
        #expect(HomeCache.usage(connection: own, profile: "default", days: 30, ephemeral: false, in: d)?.totals?.totalSessions == 2)
        // Another bot, range or "chats from" has its own, and nothing kept yet.
        #expect(HomeCache.sessions(connection: own, profile: "default", allBots: true, ephemeral: false, in: d) == nil)
        #expect(HomeCache.sessions(connection: own, profile: "gizmo", allBots: false, ephemeral: false, in: d) == nil)
        #expect(HomeCache.usage(connection: own, profile: "default", days: 7, ephemeral: false, in: d) == nil)
    }

    /// Never the demo's, never an in-process gateway's (#493), and no key ever holds the demo's id: what the replay's
    /// fingerprint can't see in Home's kept numbers (it counts them by being there), these hold.
    @Test func theDemosAndAnInProcessGatewaysHomeAreNeverKept() throws {
        let (d, suite) = try scratchDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let demo = GatewayConnection.demoID
        HomeCache.save(sessions: list, connection: demo, profile: "default", allBots: false, ephemeral: true, in: d)
        HomeCache.save(usage: try usage(2), connection: demo, profile: "default", days: 30, ephemeral: true, in: d)
        // The demo's id even where the caller doesn't say it runs in-process.
        HomeCache.save(sessions: list, connection: demo, profile: "default", allBots: false, ephemeral: false, in: d)
        HomeCache.save(usage: try usage(2), connection: demo, profile: "default", days: 30, ephemeral: false, in: d)
        let inProcess = UUID()
        HomeCache.save(sessions: list, connection: inProcess, profile: "default", allBots: false, ephemeral: true, in: d)
        HomeCache.save(usage: try usage(2), connection: inProcess, profile: "default", days: 30, ephemeral: true, in: d)
        let kept = d.dictionaryRepresentation().keys.filter { $0.hasPrefix(HomeCache.prefix) }
        #expect(kept.isEmpty, "kept \(kept)")
        // One an older build planted is never read back.
        d.set(try JSONEncoder().encode(list), forKey: HomeCache.sessionsKey(connection: demo, profile: "default", allBots: false))
        #expect(HomeCache.sessions(connection: demo, profile: "default", allBots: false, ephemeral: false, in: d) == nil)
        // And the demo's sweep takes such a key (it holds the demo's id).
        DemoTraces.sweep(defaults: d, caches: nil)
        #expect(d.object(forKey: HomeCache.sessionsKey(connection: demo, profile: "default", allBots: false)) == nil)
    }

    @Test func removingAGatewayTakesItsHomeAndOnlyIts() throws {
        let (d, suite) = try scratchDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let gone = UUID(), stays = UUID()
        for c in [gone, stays] {
            HomeCache.save(sessions: list, connection: c, profile: "default", allBots: false, ephemeral: false, in: d)
            HomeCache.save(usage: try usage(2), connection: c, profile: "default", days: 30, ephemeral: false, in: d)
        }
        HomeCache.forget(connection: gone, in: d)
        #expect(HomeCache.sessions(connection: gone, profile: "default", allBots: false, ephemeral: false, in: d) == nil)
        #expect(HomeCache.usage(connection: gone, profile: "default", days: 30, ephemeral: false, in: d) == nil)
        #expect(HomeCache.sessions(connection: stays, profile: "default", allBots: false, ephemeral: false, in: d) != nil)
        #expect(HomeCache.usage(connection: stays, profile: "default", days: 30, ephemeral: false, in: d) != nil)
    }

    /// Settings' "Clear chat list cache" and its size take Home's kept data too; the chat lists' own keys as before. On a
    /// defaults suite of the test's own: the test host's standard defaults may be a real app's, so no test clears them.
    @Test func settingsClearAndSizeCoverHomesKeptData() throws {
        let (d, suite) = try scratchDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let own = UUID()
        let chatKey = SessionCache.key(connection: own, profile: "default"), other = "home.layout"
        d.set(try JSONEncoder().encode(list), forKey: chatKey)
        d.set("[]", forKey: other)
        let chatsOnly = SessionCache.approximateBytes(in: d)
        HomeCache.save(sessions: list, connection: own, profile: "default", allBots: false, ephemeral: false, in: d)
        HomeCache.save(usage: try usage(2), connection: own, profile: "default", days: 30, ephemeral: false, in: d)
        #expect(SessionCache.approximateBytes(in: d) > chatsOnly, "Home's kept data not counted")
        SessionCache.clearAll(in: d)
        #expect(d.object(forKey: HomeCache.sessionsKey(connection: own, profile: "default", allBots: false)) == nil)
        #expect(d.object(forKey: HomeCache.usageKey(connection: own, profile: "default", days: 30)) == nil)
        #expect(d.object(forKey: chatKey) == nil, "the chat lists' own key stayed")
        #expect(d.string(forKey: other) == "[]", "the clear took a setting that isn't a cache")
        #expect(SessionCache.approximateBytes(in: d) == 0)
        #expect(!HomeCache.sessionsKey(connection: own, profile: nil, allBots: false).hasPrefix(SessionCache.prefix + own.uuidString),
                "Chats' loadAny would read Home's list")
    }
}
