import Foundation
import Testing
@testable import Vory

/// Status's Companion row says what to do: an older companion is to be updated, not restarted, and a gateway running
/// older code than its disk holds is to be restarted. Read from a setup model set as the companion check leaves it.
@MainActor @Suite struct CompanionStatusLineTests {
    static func setup(installed: String, scriptMatches: Bool, running: String, runningScript: String) throws -> PushSetupModel {
        let object: [String: Any] = ["version": running, "script_sha256": runningScript, "updated_at": Date().timeIntervalSince1970, "connected": true]
        let s = PushSetupModel()
        s.installedVersion = installed
        s.installedScriptMatches = scriptMatches
        s.heartbeat = try JSONDecoder().decode(PushSetupModel.CompanionHeartbeat.self, from: JSONSerialization.data(withJSONObject: object))
        return s
    }

    @Test func eachCompanionStateGetsItsOwnLine() throws {
        let older = String(repeating: "0", count: 64)
        let current = PushSetupModel.bundledScriptSHA256
        // An older companion running, and the same one on the gateway's disk: update it.
        let olderEverywhere = CompanionStatusLine.of(try Self.setup(installed: "1.0.40", scriptMatches: false, running: "1.0.40", runningScript: older))
        #expect(olderEverywhere.contains("Update it from Settings"), "an older companion: \(olderEverywhere)")
        #expect(!olderEverywhere.contains("has not restarted"), "an older companion: \(olderEverywhere)")
        // This build's companion on the disk, the older one still running: restart.
        let notRestarted = CompanionStatusLine.of(try Self.setup(installed: "1.0.41", scriptMatches: true, running: "1.0.40", runningScript: older))
        #expect(notRestarted.hasPrefix("Installed (1.0.41) but the gateway has not restarted with it yet"), "not restarted: \(notRestarted)")
        #expect(!notRestarted.contains("Update it"), "not restarted: \(notRestarted)")
        // Everything current: neither line.
        let running = CompanionStatusLine.of(try Self.setup(installed: "1.0.41", scriptMatches: true, running: "1.0.41", runningScript: current))
        #expect(running == "Running, version 1.0.41", "current: \(running)")
    }
}
