import AppKit
import SwiftUI

/// The logged-out alerts (CQ·130), drawn over the top of the Deck window.
/// Attached to the window root in `DeckApp`, not inside `ContentView.body`,
/// whose modifier chain is at the type checker's budget on the release
/// toolchain (see `ContentView.windowContent`).
///
/// Clears alerts from `railState`'s known states: a host that reads logged
/// in again drops its alert without the operator touching it.
struct DesktopSessionAlertStack: View {
    @ObservedObject var alerts: DesktopSessionAlertCenter
    @ObservedObject var railState: RailStateModel
    @ObservedObject var store: ThemeStore

    var body: some View {
        Group {
            if !alerts.alerts.isEmpty {
                VStack(spacing: 8) {
                    ForEach(alerts.alerts) { alert in
                        DesktopSessionAlertCard(
                            alert: alert,
                            onOpenRunbook: { alerts.openRunbook(for: alert) },
                            onOpenScreenSharing: {
                                if let url = alert.screenSharing { NSWorkspace.shared.open(url) }
                            },
                            onDismiss: { alerts.dismiss(hostName: alert.hostName) })
                    }
                }
                .padding(12)
            }
        }
        .onChange(of: railState.desktopSessionKnownState) { _, states in
            alerts.reconcile(knownStates: states, hosts: store.configuration.hosts)
        }
    }
}

/// One host's logged-out alert: what happened, what stops, and the actions
/// that continue. Draws its own surface so it reads over the
/// window's content in either appearance.
struct DesktopSessionAlertCard: View {
    let alert: LoggedOutAlert
    let onOpenRunbook: () -> Void
    let onOpenScreenSharing: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(alert.hostName) is logged out")
                        .font(.headline)
                    Text(verbatim: "The account \(alert.account) on \(alert.hostName) has no desktop session. "
                         + "Until \(alert.account) is logged in there, "
                         + "its per-user services (LaunchAgents) stop running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }

            if alert.runbook != nil {
                Text(verbatim: "The runbook has the steps to log \(alert.account) back in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if alert.screenSharing != nil {
                Text(verbatim: "To continue, open Screen Sharing to \(alert.hostName), then choose "
                     + "Log In as \(alert.account).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: "To continue, log \(alert.account) in on \(alert.hostName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(alert.buttons, id: \.self) { button in
                    switch button {
                    case .openRunbook:
                        Button("Open Runbook", action: onOpenRunbook)
                    case .openScreenSharing:
                        Button("Open Screen Sharing", action: onOpenScreenSharing)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
