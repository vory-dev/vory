import SwiftUI
import VoryCore

/// Small glass status pill used in navigation bars.
struct ConnectionPill: View {
    var state: SocketState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Connection: \(state.label)")
    }
    private var color: Color {
        switch state {
        case .open: return .green
        // A restart reads as reconnecting: the gateway is coming back.
        case .connecting, .reconnecting, .unreachable(.restarting, _): return .orange
        case .authRejected, .failed, .unreachable: return .red
        case .idle: return .gray
        }
    }
}
