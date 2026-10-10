import Foundation

/// Coordinates cross-window navigation into Settings — driven by
/// `UnresolvedHostView`'s primary action. A hover tooltip is not a way in
/// (see `deck/specs/multiple-sessions-per-project`'s lesson from #111), and
/// Settings itself has no notion of a route to open to until something
/// outside it asks for one.
///
/// One instance, shared by `DeckApp` between the main `WindowGroup` and the
/// `Settings` scene, since a route requested from the main window has to be
/// read by a view living in a different scene entirely.
@MainActor
final class SettingsNavigation: ObservableObject {
    enum Tab: Hashable {
        case general, text, sessions, hosts, signing
    }

    @Published var selectedTab: Tab = .general

    /// A fresh value on every request, not a toggled bool — `onChange` only
    /// fires on a change, so a bool already `true` from a prior request
    /// would not fire again if Settings is still open and the empty state
    /// is clicked a second time.
    @Published var addHostRequestToken: UUID?

    func openHostsWithAddSheet() {
        selectedTab = .hosts
        addHostRequestToken = UUID()
    }

    /// A fresh value per request, the same reason `addHostRequestToken` is —
    /// a logged-out alert with no runbook link (CQ·124) switches to this tab
    /// and selects the host's own row, so pressing its button twice for the
    /// same host still re-selects and is not read as no change.
    @Published var selectHostRequest: String?

    func openHostsSettings(selecting hostName: String) {
        selectedTab = .hosts
        selectHostRequest = hostName
    }

    /// `HostsSettingsView` calls this once it has acted on a pending
    /// selection request — the same one-shot discipline
    /// `consumeAddHostRequest` follows. Returns the name to select, or nil
    /// when there was no pending request.
    @discardableResult
    func consumeSelectHostRequest() -> String? {
        let name = selectHostRequest
        selectHostRequest = nil
        return name
    }

    /// Switches to Settings › Sessions, where a crew's `workingDirectory`
    /// field lives (`SessionRoster`/`SessionsSettingsView`) — the fix for a
    /// row `MissingDirectoryView` reports as unstartable. No request token:
    /// unlike the Hosts tab's Add sheet, there is no sheet to open, only an
    /// existing row to select and edit.
    func openSessionsSettings() {
        selectedTab = .sessions
    }

    /// `HostsSettingsView` calls this once it has acted on a pending
    /// request (opened its Add sheet), so the token is one-shot: a later
    /// re-materialization of that view — or any other `initial: true`
    /// observer — sees `nil` rather than re-firing on a stale value.
    /// Returns whether there was a request to consume.
    @discardableResult
    func consumeAddHostRequest() -> Bool {
        guard addHostRequestToken != nil else { return false }
        addHostRequestToken = nil
        return true
    }
}
