import Foundation
import Testing
@testable import VoryCore

/// A message's pictures reach a migrated gateway's turn as `prompt.submit`'s `attachments`, the way its admission takes
/// them: each exactly its path and mime, in order, at most ten, and no list at all when there are none.
@Suite struct SubmitAttachmentsTests {
    static let mimes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    @Test(arguments: [0, 1, 10, 11])
    func aMessagesPicturesGoAsTheGatewayTakesThem(count: Int) throws {
        let pictures = (0..<count).map { ChatSession.StagedPicture(path: "/cache/images/p\($0).img", mime: Self.mimes[$0 % 4]) }
        let (param, over) = ChatSession.submitAttachments(pictures)
        guard count > 0 else {
            #expect(param == nil, "an empty list went, which the gateway refuses")
            #expect(over.isEmpty)
            return
        }
        let sent = try #require(param?.arrayValue, "no attachments for \(count) pictures")
        #expect(sent.count == min(count, 10), "\(sent.count) pictures went; the gateway takes at most ten")
        for (i, item) in sent.enumerated() {
            #expect(item == .object(["path": .string(pictures[i].path), "mime": .string(pictures[i].mime)]),
                    "picture \(i) isn't exactly its path and mime, in order")
        }
        #expect(over == Array(min(count, 10)..<count), "the pictures past ten weren't named")
    }
}
