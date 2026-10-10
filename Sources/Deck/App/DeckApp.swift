import AppKit
import SwiftUI

/// Stops every live `SessionStateFollower` before the process exits.
///
/// `applicationWillTerminate` is the last point in AppKit's terminate
/// sequence that still runs application code — the exit that follows it does
/// not go through ordinary Swift deallocation, so nothing else in Deck would
/// ever call `stop()` on a follower still registered at quit. See
/// `FollowerRegistry` for why that gap is the one this codebase actually hit.
final class DeckAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        FollowerRegistry.shared.stopAll()
    }
}

@main
struct DeckApp: App {
    @NSApplicationDelegateAdaptor(DeckAppDelegate.self) private var appDelegate

    /// Owned here rather than in ContentView so the menu commands below can
    /// reach the same configuration the canvas draws from. `.commands` is built
    /// at App scope, outside any view's `@State`.
    @StateObject private var store = ThemeStore()

    /// Phase 2 file viewer: loopback server for PDF and HTML hand-off to the
    /// browser. Started in `.task` below so it outlives any single window and
    /// is available as soon as the first file reference is clicked.
    @StateObject private var server = WorkingCopyServer()

    /// Shared with the `Settings` scene below so a route requested from the
    /// main window (the empty state's "Add a Host" button) can be read by a
    /// view living in a different scene entirely. See `SettingsNavigation`.
    @StateObject private var settingsNavigation = SettingsNavigation()

    /// Owned here rather than in `ContentView`, for the same reason `store`
    /// is: `SessionsSettingsView`, in the `Settings` scene below, needs the
    /// same `servedCrews` reading the rail draws from, or a crew served with
    /// no local config at all reaches the rail and never reaches Settings
    /// (`issue_01M2P6E8EQHDMWFY02Q4GVMZ7R`).
    @StateObject private var railState = RailStateModel()

    /// The logged-out alerts (CQ·124, CQ·130) — owned here, alongside the
    /// other app-scope state above, rather than in `ContentView`, for the
    /// same reason `railState` is: the alert stack attaches at the window
    /// root below, outside `ContentView`.
    @StateObject private var desktopAlerts = DesktopSessionAlertCenter()

    var body: some Scene {
        WindowGroup("Convivy Builder") {
            ContentView()
                .environmentObject(store)
                .environmentObject(server)
                .environmentObject(settingsNavigation)
                .environmentObject(railState)
                .environmentObject(desktopAlerts)
                // A bind failure (no loopback) surfaces through server.bindError
                // so ContentView can show an alert. In practice the loopback
                // interface is always up, but swallowing the error silently
                // made PDF and HTML hand-off fail with no explanation.
                .task {
                    do { try await server.start() }
                    catch { server.bindError = error }
                }
                // The logged-out alerts (CQ·130) sit over the window's top edge.
                // Attached here rather than in `ContentView.body`, whose chain is
                // at the type checker's budget on the release toolchain.
                .overlay(alignment: .top) {
                    DesktopSessionAlertStack(
                        alerts: desktopAlerts, railState: railState, store: store)
                }
        }
        .commands {
            // Cmd-+/-/0 is the terminal idiom, and leaving font size to a
            // config file alone would repeat the mistake the theme picker
            // fixed: the file is storage, not the interface.
            CommandGroup(after: .toolbar) {
                Button("Bigger Text") { store.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!store.canIncreaseFontSize)

                Button("Smaller Text") { store.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!store.canDecreaseFontSize)

                Button("Actual Size") { store.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()
            }
        }

        // Cmd-, and an App menu item, both supplied by the scene. Deck's
        // preferences were reachable only from the surface each one affected,
        // or from the config file; this is the place a Mac user looks first.
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settingsNavigation)
                .environmentObject(railState)
                .environmentObject(desktopAlerts)
        }
    }
}
