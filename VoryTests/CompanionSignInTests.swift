import Foundation
import Testing
@testable import Vory

/// #764: the Companion screen says when the gateway has turned down the companion's sign-in, read from the
/// heartbeat the companion already writes. Only a fresh heartbeat, not connected, with the companion's own words
/// counts; anything else leaves the row as it was.
@MainActor @Suite struct CompanionSignInTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A heartbeat as the companion writes it to status.json, `age` seconds before `now`.
    static func beat(connected: Bool, error: String?, age: TimeInterval) throws -> PushSetupModel.CompanionHeartbeat {
        var object: [String: Any] = ["version": "1.0.41", "updated_at": now.timeIntervalSince1970 - age, "connected": connected]
        if let error { object["error"] = error }
        return try JSONDecoder().decode(PushSetupModel.CompanionHeartbeat.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func refused(_ beat: PushSetupModel.CompanionHeartbeat?) -> Bool {
        PushSetupModel.companionSignInRefused(beat, now: now)
    }

    @Test func aTurnedDownCompanionSignInIsSaid() throws {
        // "sign-in rejected" is the companion's own text, from server/hermes-push/hermes_push.py; its tests pin it too.
        let turnedDown = "http://127.0.0.1:9119: HTTP 401 Unauthorized (sign-in rejected: sign in for the companion again. A Hermes update can end every sign-in once.)"
        let fresh = try Self.beat(connected: false, error: turnedDown, age: 5)
        let stale = try Self.beat(connected: false, error: turnedDown, age: 61)
        let connected = try Self.beat(connected: true, error: turnedDown, age: 5)
        let nothingListening = try Self.beat(connected: false, error: "http://127.0.0.1:9119: connection refused (nothing listens there on this machine)", age: 5)
        let cloudflare = try Self.beat(connected: false, error: "https://gateway.example.test: HTTP 403 Forbidden (Cloudflare blocked it: the companion needs the Access service token, or use a loopback URL)", age: 5)
        #expect(Self.refused(fresh), "fresh, not connected, the words")
        #expect(!Self.refused(stale), "61 s old")
        #expect(!Self.refused(connected), "connected")
        #expect(!Self.refused(nothingListening), "nothing listening")
        #expect(!Self.refused(cloudflare), "Cloudflare")
        #expect(!Self.refused(nil), "no heartbeat")
    }
}
