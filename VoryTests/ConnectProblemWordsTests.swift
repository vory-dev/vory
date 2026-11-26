import Foundation
import Testing
@testable import VoryCore

/// The words for a sign-in the gateway refused.
@Suite struct ConnectProblemWordsTests {
    @Test func aRefusedSessionTokenNamesTheWebappFile() {
        let words = ConnectProblem.refusedWords(why: "Unauthorized", authMode: .sessionToken)
        #expect(words.contains("webapp/session-token"), "\(words)")
        #expect(words.contains("If Hermes was updated"), "\(words)")
        #expect(!words.contains("Unauthorized"))
        // Whatever the refresh did, a session token's refusal is the token's.
        #expect(ConnectProblem.refusedWords(why: "x", authMode: .sessionToken, refreshRefused: true) == words)
    }

    @Test func aRefreshTheGatewayRefusedSaysWhy() {
        for mode in [AuthMode.password, .oauth] {
            let ended = ConnectProblem.refusedWords(why: "x", authMode: mode, refreshRefused: true).lowercased()
            #expect(ended.contains("sign in again"), "\(mode): \(ended)")
            #expect(ended.contains("hermes update"), "\(mode): \(ended)")
            // A refusal that isn't a refused refresh keeps its own words.
            #expect(ConnectProblem.refusedWords(why: "x", authMode: mode, refreshRefused: false) == "x")
        }
    }
}
