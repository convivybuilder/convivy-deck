import Foundation

/// One in-window alert for a host whose account read logged out (CQ·124).
/// Captured when the transition lands, so the alert keeps the host name,
/// account and runbook it was raised with.
struct LoggedOutAlert: Equatable, Identifiable {
    let target: SSHTarget
    let hostName: String
    /// The host's `user`, the account that came back without a desktop session.
    let account: String
    /// The host's runbook, validated with `RunbookLink.parse` when the alert
    /// is raised. Nil when no runbook is set or the stored text does not parse.
    let runbook: RunbookLink?
    /// The `vnc://` URL for the Screen Sharing button, built when the alert is
    /// raised. Nil when the host's address cannot form one, which drops the button.
    let screenSharing: URL?

    var id: String { hostName }

    /// The action buttons this alert draws, in layout order. The card draws
    /// exactly this list, so a test pins which buttons each branch gets.
    var buttons: [LoggedOutAlertButton] {
        var buttons: [LoggedOutAlertButton] = []
        if runbook != nil { buttons.append(.openRunbook) }
        if screenSharing != nil { buttons.append(.openScreenSharing) }
        return buttons
    }
}

enum LoggedOutAlertButton: Hashable {
    case openRunbook
    case openScreenSharing
}

/// Holds the logged-out alerts Deck shows inside its own window, in place of
/// a macOS notification (CQ·130). Needs no notification permission, so it
/// works for an ad-hoc signed build.
///
/// Bridges `RailStateModel`'s desktop-session transitions to alerts: a
/// transition raises one alert, a dismiss removes it, and a host that reads
/// logged in again clears it. Alerts are keyed by host name, so two hosts
/// logging out show two alerts.
@MainActor
final class DesktopSessionAlertCenter: ObservableObject {
    /// One alert per host, in the order their transitions landed.
    @Published private(set) var alerts: [LoggedOutAlert] = []

    /// What an alert's "Open Runbook" asks the shell to do — a fresh value per
    /// press, the same one-shot-request idiom `SettingsNavigation
    /// .addHostRequestToken` uses, since `onChange` only fires on a value
    /// that actually changes and two presses for the same host must each
    /// still be acted on.
    struct RunbookOpenRequest: Equatable {
        let token: UUID
        let hostName: String
        /// The stored `runbookLink` text, re-validated by the shell with
        /// `RunbookLink.parse` before it opens anything — this struct
        /// carries the raw string across the view boundary, not a trusted
        /// `RunbookLink`.
        let rawLink: String?
    }

    @Published private(set) var pendingRunbookOpen: RunbookOpenRequest?

    /// Called from `RailStateModel.onDesktopSessionLoggedOut`, which fires
    /// once per transition (`DesktopSessionTracker.apply`). A target that
    /// resolves to no configured host raises nothing: there is no host left
    /// to name or to recover. A host that already has an alert is not
    /// alerted twice.
    func raiseLoggedOut(target: SSHTarget, hosts: [HostEntry]) {
        guard let host = hosts.first(where: { SSHTarget(user: $0.user, host: $0.address) == target }),
              !alerts.contains(where: { $0.hostName == host.name })
        else { return }
        alerts.append(LoggedOutAlert(
            target: target, hostName: host.name, account: host.user,
            runbook: host.runbookLink.flatMap(RunbookLink.parse),
            screenSharing: ScreenSharingLink.url(forAddress: host.address)))
    }

    func dismiss(hostName: String) {
        alerts.removeAll { $0.hostName == hostName }
    }

    /// Removes every alert whose host no longer reads logged out, or no
    /// longer exists in `hosts`. Only a `.loggedIn` reading clears an alert:
    /// an unknown reading never reaches `knownStates`, because
    /// `DesktopSessionTracker` holds the last definite state through it.
    func reconcile(knownStates: [SSHTarget: DesktopSessionKnownState], hosts: [HostEntry]) {
        let kept = alerts.filter { alert in
            knownStates[alert.target] == .loggedOut
                && hosts.contains { SSHTarget(user: $0.user, host: $0.address) == alert.target }
        }
        if kept != alerts { alerts = kept }
    }

    /// Asks the shell to open `alert`'s runbook through the existing
    /// `openRunbookLink` path. The alert stays up until it is dismissed or
    /// the host reads logged in.
    func openRunbook(for alert: LoggedOutAlert) {
        pendingRunbookOpen = RunbookOpenRequest(
            token: UUID(), hostName: alert.hostName, rawLink: alert.runbook?.stored)
    }

    /// The shell calls this once it has acted on `pendingRunbookOpen` — the
    /// same one-shot consume `SettingsNavigation.consumeAddHostRequest`
    /// follows, so a later re-materialization of an observer never re-opens
    /// a stale request.
    func consumePendingRunbookOpen() {
        pendingRunbookOpen = nil
    }
}
