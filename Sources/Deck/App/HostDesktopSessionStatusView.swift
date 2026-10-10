import SwiftUI

/// The desktop-session status line in a host's Settings › Hosts detail
/// panel (CQ·124). The logged-out alert itself is `DesktopSessionAlertCard`;
/// this line stays after the alert is dismissed, so Settings still says
/// what the host reads.
///
/// A SEPARATE LEAF VIEW, not inlined into `HostsSettingsView.detail`, so it
/// can be rendered and measured on its own without pulling in
/// `HostsSettingsView`'s full environment (`ThemeStore`, `SettingsNavigation`,
/// a live `RailStateModel`).
struct HostDesktopSessionStatusView: View {
    let hostName: String
    let knownState: DesktopSessionKnownState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if knownState == .loggedOut {
                Label("The account on \(hostName) is logged out.",
                      systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
