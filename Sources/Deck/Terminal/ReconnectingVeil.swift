import SwiftUI

/// Dims the pane and shows retry status on connection loss (fork 1: "dim the
/// panes with a 'reconnecting' veil"). Never blocks input to the pane below
/// it once reconnected — `allowsHitTesting(false)` keeps the veil purely
/// visual.
struct ReconnectingVeil: View {
    let phase: ConnectionStateMachine.Phase
    /// The pinned appearance of the terminal this veil covers, or `nil` under
    /// `system`, which pins nothing. The spinner draws from the colour scheme in
    /// the environment. Under Light, Dark and Builder Default that scheme can
    /// differ from the system's, so the veil pins it; under `system` the veil
    /// leaves the window's scheme alone.
    let appearance: Appearance?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
        }
        .transformEnvironment(\.colorScheme) { scheme in
            if let pinned = Self.pinnedScheme(for: appearance) { scheme = pinned }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// The colour scheme the veil writes into the environment, or `nil` to
    /// write none.
    static func pinnedScheme(for appearance: Appearance?) -> ColorScheme? {
        appearance.map { $0 == .dark ? .dark : .light }
    }

    private var message: String {
        switch phase {
        case .connecting:
            return "Connecting…"
        case .connected:
            return ""
        case .reconnecting(let attempt, let delay):
            return "Reconnecting (attempt \(attempt)) — retrying in \(Int(delay.rounded()))s"
        }
    }
}
