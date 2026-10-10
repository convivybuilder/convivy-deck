import Foundation
@testable import Deck

/// The one host every test that needs an `SSHTarget` should use, rather than
/// each file inventing its own literal.
///
/// `192.0.2.1` is RFC 5737 TEST-NET-1 — reserved for documentation, never a
/// real address — the same placeholder `HostPlaceholderTests` pins for
/// on-screen placeholder text. `operator` is a generic account name, not
/// anyone's.
enum TestHost {
    static let user = "operator"
    static let address = "192.0.2.1"
    static let target = SSHTarget(user: user, host: address)

    /// `user`'s macOS home directory, built from two literals rather than
    /// one so no single string in this file spells out a full `/Users/<account>`
    /// path.
    static let homeRoot = "/Users/" + user

    /// A second, distinct host for tests exercising cross-host behavior
    /// (two hosts in `hosts`, a session discovered on one but not the
    /// other) — same reserved range, a different address within it.
    static let secondaryUser = "guest"
    static let secondaryAddress = "192.0.2.2"
    static let secondaryTarget = SSHTarget(user: secondaryUser, host: secondaryAddress)
    static let secondaryHomeRoot = "/Users/" + secondaryUser

    /// A host for a test that needs a REAL `SessionAgent`/`LibraryClient`
    /// call to actually run and fail, fast, rather than a seam intercepting
    /// it first. `.invalid` is RFC 2606-reserved — guaranteed never to
    /// resolve — so ssh fails on DNS lookup in milliseconds. `target`
    /// (192.0.2.1, RFC 5737) is unreachable too, but a live connect *attempt*
    /// to it blocks on the OS's own TCP connect timeout with nothing in this
    /// codebase bounding it below that (measured: still unresolved past 12s),
    /// which is why no existing test lets a real call reach it.
    static let unreachableTarget = SSHTarget(user: "operator", host: "cockpit-test.invalid")
}
