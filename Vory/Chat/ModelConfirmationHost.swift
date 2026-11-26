import SwiftUI
import VoryCore

/// Which of a chat's views asks a model pick's question (`modelConfirmationHost`). An alert can't be presented from a
/// view a sheet covers, so the chat page, the bot card and each model sheet carry the same alert, and one of them asks:
/// the last put on screen, counting every sheet and this chat's own pages (a page beside it, on the Duo, covers
/// nothing). While a sheet that doesn't ask is up (`modelConfirmationCover`: the compose sheet, as its chat opens
/// under it, and every other sheet or cover over a chat), none asks, so a question waits for it to go rather than
/// being presented under it and lost. Each counts from its appearance to its disappearance, which SwiftUI calls once a
/// sheet has gone, so a question never races a sheet's closing.
@MainActor @Observable final class ModelConfirmationHosts {
    static let shared = ModelConfirmationHosts()
    enum Place { case page, sheet }
    private struct Host { var id: UUID; var chat: ObjectIdentifier; var place: Place }
    private var hosts: [Host] = []
    private var covers: Set<UUID> = []

    func appeared(_ id: UUID, chat: ChatSession, in place: Place) {
        hosts.removeAll { $0.id == id }
        hosts.append(Host(id: id, chat: ObjectIdentifier(chat), place: place))
    }

    func covered(_ id: UUID) { covers.insert(id) }

    func disappeared(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        covers.remove(id)
    }

    /// Whether the view `id` asks `chat`'s question now.
    func asks(_ id: UUID, for chat: ChatSession) -> Bool {
        guard covers.isEmpty else { return false }
        let c = ObjectIdentifier(chat)
        return hosts.last { $0.place == .sheet || $0.chat == c }?.id == id
    }
}

/// The question itself: a stock alert whose title is the model and whose words are the gateway's own. Only its buttons
/// answer it (its setter does nothing), each for the offer it showed, so its closing never undoes a yes.
private struct ModelConfirmationAlert: ViewModifier {
    let chat: ChatSession?
    let place: ModelConfirmationHosts.Place
    let onUse: () -> Void
    @State private var id = UUID()
    /// The Mac keeps visited pages mounted behind the one on show, so a hidden page never disappears. Hidden, it isn't
    /// a host: its question waits until the page is shown again, rather than showing over another page. Always true on
    /// the iPhone and in sheets.
    @Environment(\.macPageShown) private var pageShown

    func body(content: Content) -> some View {
        let hosts = ModelConfirmationHosts.shared
        let shown = chat.flatMap { hosts.asks(id, for: $0) ? $0.pendingModelConfirmation : nil }
        content
            .alert(shown?.model ?? "", isPresented: Binding(get: { shown != nil }, set: { _ in }), presenting: shown) { c in
                Button("Use \(c.model)") { if chat?.acceptModelConfirmation(c) == true { onUse() } }
                Button("Cancel", role: .cancel) { chat?.cancelModelConfirmation() }
            } message: { c in
                Text(c.message)
            }
            .onAppear { arrive(hosts) }
            .onDisappear { hosts.disappeared(id) }
            .onChange(of: pageShown) { _, shown in
                guard place == .page else { return }
                if shown { arrive(hosts) } else { hosts.disappeared(id) }
            }
    }

    /// On screen: a host for its chat, or a cover with none. A Mac page hidden behind the one on show counts as gone.
    private func arrive(_ hosts: ModelConfirmationHosts) {
        guard place == .sheet || pageShown else { return }
        if let chat { hosts.appeared(id, chat: chat, in: place) } else { hosts.covered(id) }
    }
}

extension View {
    /// Asks `chat`'s model question here when this view is on top (`ModelConfirmationHosts`); `onUse` runs after Use
    /// (a model sheet closes). With no chat, a sheet that doesn't ask: `modelConfirmationCover`.
    func modelConfirmationHost(_ chat: ChatSession?, in place: ModelConfirmationHosts.Place, onUse: @escaping () -> Void = {}) -> some View {
        modifier(ModelConfirmationAlert(chat: chat, place: place, onUse: onUse))
    }

    /// A sheet that doesn't ask: while it's up no chat's question shows, then the view under it asks.
    func modelConfirmationCover() -> some View { modelConfirmationHost(nil, in: .sheet) }
}
