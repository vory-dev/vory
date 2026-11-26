import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The socket's credential arrives whole: every character outside RFC 3986's unreserved set is percent-encoded.
/// Everything else the socket URLs carry stays as it was.
@Suite struct SocketCredentialEncodingTests {
    static let gateway = try! GatewayURL.normalize("http://127.0.0.1:9129")
    /// A test credential holding each character a query could misread.
    static let awkward = "a+b&c=d#e f%g"

    /// The URL the socket builder made before the credential had its own encoding: every item, the credential last,
    /// through URLComponents.queryItems.
    static func plainBuild(_ path: String, _ items: [URLQueryItem]) -> String {
        var c = URLComponents(url: gateway.base, resolvingAgainstBaseURL: false)!
        c.scheme = gateway.isTLS ? "wss" : "ws"
        c.path = gateway.pathPrefix + path
        c.queryItems = items.isEmpty ? nil : items
        return c.url!.absoluteString
    }

    @Test func aSessionTokenIsFullyEncodedInTheSocketURL() {
        let url = RequestSigner.websocketURL(gateway: Self.gateway, token: Self.awkward, ticket: nil)
        print("socket URL for the test token: \(url.absoluteString)")
        #expect(url.query(percentEncoded: true) == "token=a%2Bb%26c%3Dd%23e%20f%25g")
    }

    @Test func aTicketIsFullyEncodedInTheSocketURL() {
        let url = RequestSigner.websocketURL(gateway: Self.gateway, token: nil, ticket: Self.awkward)
        print("socket URL for the test ticket: \(url.absoluteString)")
        #expect(url.query(percentEncoded: true) == "ticket=a%2Bb%26c%3Dd%23e%20f%25g")
    }

    @MainActor @Test func theSocketURLsOtherItemsStayByteForByte() async throws {
        // A URL-safe ticket and token, as Hermes mints them: their bytes don't change.
        let ticket = "Ab_9-xY.z~", token = "tok"
        #expect(RequestSigner.websocketURL(gateway: Self.gateway, token: nil, ticket: ticket).absoluteString
                == Self.plainBuild("/api/ws", [URLQueryItem(name: "ticket", value: ticket)]))
        #expect(RequestSigner.websocketURL(gateway: Self.gateway, token: token, ticket: nil).absoluteString
                == Self.plainBuild("/api/ws", [URLQueryItem(name: "token", value: token)]))
        // A plugin's socket: its own items as they were, characters a query leaves bare among them, then the token.
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "encoding", gateway: Self.gateway, authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: token))
        defer { store.delete(id: conn.id) }
        let runtime = GatewayRuntime(connection: conn, store: store)
        let kanban = [URLQueryItem(name: "board", value: "b:1/2 x"), URLQueryItem(name: "since", value: "17+3")]
        let (k, _) = try await runtime.pluginWebsocketURL(path: "/api/plugins/kanban/events", query: kanban)
        #expect(k.absoluteString == Self.plainBuild("/api/plugins/kanban/events", kanban + [URLQueryItem(name: "token", value: token)]))
        let voice = [URLQueryItem(name: "profile", value: "writer")]
        let (v, _) = try await runtime.pluginWebsocketURL(path: "/api/audio/speak-stream", query: voice)
        #expect(v.absoluteString == Self.plainBuild("/api/audio/speak-stream", voice + [URLQueryItem(name: "token", value: token)]))
    }
}
