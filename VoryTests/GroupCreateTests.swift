import Foundation
import Testing
@testable import VoryCore

@Suite struct GroupCreateTests {
    /// Hermes takes a room id that starts with a letter or digit, then letters, digits and `._:-`, at most 128.
    @Test func aGroupIsCreatedWithARoomId() {
        let p = GroupCreate.params(name: "Room", members: [])
        let id = p["room_id"]?.stringValue
        #expect(id != nil)
        if let id {
            #expect(id.count <= 128)
            #expect(id.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil)
        }
        #expect(Set(p.keys) == ["room_id", "name", "members"])
    }

    /// The id the Bots page's group create mints is one Hermes takes, and new each time.
    @Test func aNewRoomsIdIsOneHermesTakes() {
        let id = GroupCreate.newRoomID()
        #expect(id.count <= 128)
        #expect(id.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil)
        #expect(GroupCreate.newRoomID() != id, "two rooms got one id")
    }
}
