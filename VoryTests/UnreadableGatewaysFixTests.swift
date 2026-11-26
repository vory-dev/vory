import Foundation
import Security
import Testing
@testable import Vory
@testable import VoryCore

/// The store's own answers once it can tell an unreadable list apart, and the Keychain migration's choices.
@MainActor
@Suite(.serialized) struct UnreadableGatewaysFixTests {
    @Test func aReadSaysWhetherTheItemIsThereAbsentOrUnreadable() {
        let memoryWas = Keychain.memoryOnly
        Keychain.memoryOnly = true
        let account = "unreadable-gateways-read-\(UUID().uuidString)"
        defer { Keychain.forcedReadStatus = nil; Keychain.delete(account: account); Keychain.memoryOnly = memoryWas }
        #expect(Keychain.read(account: account) == .absent)
        try? Keychain.set(Data([1]), account: account)
        #expect(Keychain.read(account: account) == .data(Data([1])))
        Keychain.forcedReadStatus = errSecInteractionNotAllowed
        #expect(Keychain.read(account: account) == .unreadable(errSecInteractionNotAllowed))
        #expect(Keychain.get(account: account) == nil)
        Keychain.forcedReadStatus = errSecItemNotFound
        #expect(Keychain.read(account: account) == .absent)
    }

    @Test func aListReadWhileLockedComesBackWholeOnceItCanBeRead() throws {
        try UnreadableGatewaysTests.withTwoSaved { saved in
            Keychain.forcedReadStatus = errSecInteractionNotAllowed
            let store = ConnectionStore()
            #expect(store.isUnreadable && store.connections.isEmpty)
            #expect(!store.reloadIfUnreadable(), "still locked")
            Keychain.forcedReadStatus = nil
            #expect(store.reloadIfUnreadable())
            #expect(!store.isUnreadable)
            #expect(store.connections.map(\.id) == saved)
            #expect(store.active?.id == saved.first)
        }
    }

    @Test func nothingWritesOverAListThatCantBeRead() throws {
        try UnreadableGatewaysTests.withTwoSaved { saved in
            // Removals other tests in this process made (their stores' deletes) aren't this one's: start from none. The
            // helper puts the key back after.
            UserDefaults.standard.removeObject(forKey: UnreadableGatewaysTests.removedKey)
            Keychain.forcedReadStatus = errSecInteractionNotAllowed
            let store = ConnectionStore()
            let (new, secrets) = try UnreadableGatewaysTests.gateway("New", "https://new.example.com")
            #expect(throws: ConnectionStoreError.listUnreadable) { try store.upsert(new, secrets: secrets) }
            store.delete(id: saved[0])
            #expect(store.removedHere.isEmpty)
            Keychain.forcedReadStatus = nil
            #expect(ConnectionStore().connections.map(\.id) == saved)
        }
    }

    @Test func aGatewayTheyRemoveIsKeptForThePassUntilItTakesIt() throws {
        try UnreadableGatewaysTests.withTwoSaved { saved in
            // As above: only this test's removals.
            UserDefaults.standard.removeObject(forKey: UnreadableGatewaysTests.removedKey)
            let store = ConnectionStore()
            store.delete(id: saved[0])
            store.delete(id: saved[1])
            #expect(store.removedHere == Set(saved))
            store.forgetRemoved([saved[0]])
            #expect(store.removedHere == [saved[1]])
        }
    }

    @Test func aListThatCantBeDecodedGoesAsideAndTheStoreStartsEmpty() throws {
        let defaults = UserDefaults.standard
        let knownWas = defaults.object(forKey: GatewaySyncMemory.knownKey)
        defer {
            defaults.set(knownWas, forKey: GatewaySyncMemory.knownKey)
            Keychain.delete(account: "connections.index.undecodable")
        }
        try UnreadableGatewaysTests.withTwoSaved { _ in
            defaults.set(["pushed-one", "pushed-two"], forKey: GatewaySyncMemory.knownKey)
            let bytes = Data("not a list".utf8)
            try Keychain.set(bytes, account: UnreadableGatewaysTests.index)
            let store = ConnectionStore()
            #expect(!store.isUnreadable, "a list that can't be decoded isn't waited on")
            #expect(store.connections.isEmpty)
            #expect(Keychain.read(account: "connections.index.undecodable") == .data(bytes))
            #expect(defaults.stringArray(forKey: GatewaySyncMemory.knownKey) == nil)
        }
    }

    @Test func theMigrationLeavesWhatItCantTellApart() {
        let group = "TEAMID.com.vorantx.vory.shared", old = "TEAMID.com.vorantx.vory"
        // An item the Keychain returned without its group: a delete by service and account would match the shared copy.
        #expect(Keychain.migrationStep(oldGroup: nil, group: group, inGroup: .absent) == .leave)
        #expect(Keychain.migrationStep(oldGroup: nil, group: group, inGroup: .data(Data([1]))) == .leave)
        // Already in the group.
        #expect(Keychain.migrationStep(oldGroup: group, group: group, inGroup: .data(Data([1]))) == .leave)
        // The shared copy can't be read: neither copied over nor deleted.
        #expect(Keychain.migrationStep(oldGroup: old, group: group, inGroup: .unreadable(errSecInteractionNotAllowed)) == .leave)
        // The shared copy is the one every read finds: only the old one goes.
        #expect(Keychain.migrationStep(oldGroup: old, group: group, inGroup: .data(Data([1]))) == .deleteOld)
        // No shared copy yet: copied in first, the old one going only once the copy is written.
        #expect(Keychain.migrationStep(oldGroup: old, group: group, inGroup: .absent) == .copyThenDeleteOld)
    }
}
