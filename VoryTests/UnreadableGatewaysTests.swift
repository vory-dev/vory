import Foundation
import Security
import Testing
@testable import Vory
@testable import VoryCore

/// The saved gateways when the Keychain can't be read: a phone still locked after a restart answers
/// errSecInteractionNotAllowed. That is never "no gateways", so nothing saves over the list, and nothing takes the
/// gateways this device pushed out of iCloud. The reads go through the Keychain's in-memory store, with every read
/// answering the forced status while it is set.
@MainActor
@Suite(.serialized) struct UnreadableGatewaysTests {
    static let index = "connections.index"
    static let activeKey = "activeConnectionID"
    static let removedKey = "connections.removedHere"

    static func gateway(_ name: String, _ url: String) throws -> (GatewayConnection, GatewaySecrets) {
        (GatewayConnection(name: name, gateway: try GatewayURL.normalize(url, pathPrefix: nil), authMode: .sessionToken),
         GatewaySecrets(sessionToken: "t-\(name)"))
    }

    /// Two gateways saved in the in-memory Keychain, handed to `body` by id; the Keychain, the forced status and the
    /// defaults the store writes are put back after.
    static func withTwoSaved(_ body: ([UUID]) throws -> Void) throws {
        let memoryWas = Keychain.memoryOnly
        let defaults = UserDefaults.standard
        let activeWas = defaults.object(forKey: activeKey), removedWas = defaults.object(forKey: removedKey)
        Keychain.memoryOnly = true
        Keychain.delete(account: index)
        var ids: [UUID] = []
        defer {
            Keychain.forcedReadStatus = nil
            Keychain.delete(account: index)
            for id in ids { Keychain.delete(account: "secrets." + id.uuidString) }
            Keychain.memoryOnly = memoryWas
            defaults.set(activeWas, forKey: activeKey)
            defaults.set(removedWas, forKey: removedKey)
        }
        let store = ConnectionStore()
        for (name, url) in [("Home", "https://home.example.com"), ("Work", "https://work.example.com")] {
            let (g, s) = try gateway(name, url)
            try store.upsert(g, secrets: s)
            ids.append(g.id)
        }
        try body(ids)
    }

    @Test func aGatewayAddedWhileTheListCantBeReadLeavesTheSavedOnes() throws {
        try Self.withTwoSaved { saved in
            Keychain.forcedReadStatus = errSecInteractionNotAllowed
            let locked = ConnectionStore()
            #expect(locked.connections.isEmpty)
            let (new, secrets) = try Self.gateway("New", "https://new.example.com")
            try? locked.upsert(new, secrets: secrets)
            Keychain.forcedReadStatus = nil
            #expect(ConnectionStore().connections.map(\.id) == saved, "the list a locked read couldn't give back was saved over")
        }
    }

    @Test func aListThatCantBeReadLeavesICloudAndWhatWasPushedAlone() throws {
        try Self.withTwoSaved { saved in
            let cloud = CloudGatewayTests.Cloud()
            let suite = "unreadable-gateways-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            // Read and pushed while the device could.
            CloudGateways.reconcile(store: ConnectionStore(), importNew: true, storage: cloud.storage, defaults: defaults, now: cloud.tick())
            #expect(Set(cloud.file.gateways.map(\.connection.id)) == Set(saved))
            // Then a launch that can't read the list.
            Keychain.forcedReadStatus = errSecInteractionNotAllowed
            CloudGateways.reconcile(store: ConnectionStore(), importNew: false, storage: cloud.storage, defaults: defaults, now: cloud.tick())
            #expect(Set(cloud.file.gateways.map(\.connection.id)) == Set(saved), "an unreadable list took the gateways out of iCloud")
            #expect(cloud.file.deleted.isEmpty)
            #expect(Set(defaults.stringArray(forKey: CloudGateways.knownKey) ?? []) == Set(saved.map(\.uuidString)))
        }
    }

    @Test func anEmptyListIsNeverTakenForEveryGatewayRemoved() throws {
        let cloud = CloudGatewayTests.Cloud(), phone = CloudGatewayTests.Device(cloud)
        let (g, s) = try Self.gateway("Home", "https://hermes.example.com")
        try phone.store.upsert(g, secrets: s)
        phone.sync()
        #expect(cloud.file.gateways.map(\.connection.id) == [g.id])
        // The list comes back empty, and nobody removed the gateway here.
        phone.store.connections = []
        phone.sync()
        #expect(cloud.file.gateways.map(\.connection.id) == [g.id], "an empty list took the gateway out of iCloud")
        #expect(cloud.file.deleted[g.id.uuidString] == nil)
    }

    @Test func aListThatCantBeDecodedNeverTakesTheOldGatewaysOutOfICloud() throws {
        // The pass's memory lives in the standard defaults, where the store reads and forgets it.
        let defaults = UserDefaults.standard
        let keys = [CloudGateways.knownKey, CloudGateways.stampsKey, CloudGateways.seenKey]
        let was = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, was) { defaults.set(value, forKey: key) }
            Keychain.delete(account: "connections.index.undecodable")
        }
        try Self.withTwoSaved { saved in
            let cloud = CloudGatewayTests.Cloud()
            for key in keys { defaults.removeObject(forKey: key) }
            // Read and pushed while the list could be decoded.
            CloudGateways.reconcile(store: ConnectionStore(), importNew: true, storage: cloud.storage, defaults: defaults, now: cloud.tick())
            #expect(Set(cloud.file.gateways.map(\.connection.id)) == Set(saved))
            // Then the saved list can't be decoded, and the person adds a gateway before any pass.
            try Keychain.set(Data("not a list".utf8), account: Self.index)
            let store = ConnectionStore()
            let (new, secrets) = try Self.gateway("New", "https://new.example.com")
            defer { Keychain.delete(account: "secrets." + new.id.uuidString) }
            try store.upsert(new, secrets: secrets)
            CloudGateways.reconcile(store: store, importNew: true, storage: cloud.storage, defaults: defaults, now: cloud.tick())
            #expect(Set(saved).isSubset(of: Set(cloud.file.gateways.map(\.connection.id))), "the old gateways were taken out of iCloud")
            #expect(saved.allSatisfy { cloud.file.deleted[$0.uuidString] == nil })
            #expect(Set(store.connections.map(\.id)) == Set(saved + [new.id]), "the old gateways didn't come back from iCloud")
        }
    }
}
