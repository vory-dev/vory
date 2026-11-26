import Foundation

/// The request a group chat is created with.
public enum GroupCreate {
    /// A new room's id: "room-" and ten lowercase hex characters.
    public static func newRoomID() -> String {
        "room-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    /// The params of a `groups.create` call: the room's id, its name and its members. Hermes doesn't mint room ids:
    /// it takes one that starts with a letter or digit, then letters, digits and `._:-`, at most 128 characters.
    public static func params(name: String, members: [JSONValue], roomID: String = GroupCreate.newRoomID()) -> [String: JSONValue] {
        ["room_id": .string(roomID), "name": .string(name), "members": .array(members)]
    }
}
