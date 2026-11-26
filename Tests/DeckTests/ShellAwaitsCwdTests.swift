import XCTest
@testable import Deck

/// `ContentView.shellAwaitsCwd`: the Shell column's scratch shell takes its
/// directory only when its tmux session is created, so the pane must not
/// spawn before the session's cwd lookup has answered. A pane spawned early
/// created that session in the remote home and kept it there on every later
/// attach (the operator, 2026-11-24).
final class ShellAwaitsCwdTests: XCTestCase {

    func testThePaneWaitsWhileNoCwdIsCachedAndTheLookupHasNotFinished() {
        XCTAssertTrue(ContentView.shellAwaitsCwd(cached: nil, lookupFinished: false))
    }

    func testThePaneSpawnsOnceACwdIsCached() {
        XCTAssertFalse(ContentView.shellAwaitsCwd(cached: "/srv/crews/project", lookupFinished: false))
        XCTAssertFalse(ContentView.shellAwaitsCwd(cached: "/srv/crews/project", lookupFinished: true))
    }

    /// A lookup that found no cwd still ends the wait, so the shell opens in
    /// the remote home rather than never opening.
    func testThePaneSpawnsWhenTheLookupFinishedWithoutACwd() {
        XCTAssertFalse(ContentView.shellAwaitsCwd(cached: nil, lookupFinished: true))
    }
}
