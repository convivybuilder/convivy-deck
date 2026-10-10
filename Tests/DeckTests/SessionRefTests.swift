import XCTest
@testable import Deck

/// `SessionRef` is the tuple identity phase 6b introduces — `(host, name)`
/// rather than a bare session name — per
/// `deck/specs/multiple-sessions-per-project` §"Crews on different hosts":
/// "A tmux session name is unique per machine, not globally." PURE, so
/// every case here runs with no view and no poll.
final class SessionRefTests: XCTestCase {
    // MARK: - identity

    /// The whole point of the tuple: two sessions sharing a name are the
    /// SAME ref only when their host also agrees.
    func testTwoRefsWithTheSameNameButDifferentHostsAreNotEqual() {
        let mini = SessionRef(host: "mini", name: "vivy")
        let guest = SessionRef(host: "guest", name: "vivy")
        XCTAssertNotEqual(mini, guest)
    }

    func testTwoRefsWithTheSameHostAndNameAreEqual() {
        XCTAssertEqual(SessionRef(host: "mini", name: "vivy"), SessionRef(host: "mini", name: "vivy"))
    }

    /// `nil` (the implied default host) is its own distinct value — not
    /// interchangeable with a host explicitly named the same as whatever
    /// the default happens to be, since a `SessionRef` never re-resolves
    /// its host against `hosts`/`defaultHost`.
    func testNilHostIsDistinctFromAnyNamedHost() {
        XCTAssertNotEqual(SessionRef(host: nil, name: "vivy"), SessionRef(host: "mini", name: "vivy"))
    }

    func testTwoNilHostRefsWithTheSameNameAreEqual() {
        XCTAssertEqual(SessionRef(host: nil, name: "ask"), SessionRef(host: nil, name: "ask"))
    }

    /// A `SessionRef` is usable as a dictionary key — `RailStateModel.states`
    /// and `.discovered` both key on it.
    func testARefIsHashableAndUsableAsADictionaryKey() {
        var dict: [SessionRef: Int] = [:]
        dict[SessionRef(host: "mini", name: "vivy")] = 1
        dict[SessionRef(host: "guest", name: "vivy")] = 2
        XCTAssertEqual(dict[SessionRef(host: "mini", name: "vivy")], 1)
        XCTAssertEqual(dict[SessionRef(host: "guest", name: "vivy")], 2)
    }

    // MARK: - stringForm

    func testStringFormCombinesHostAndName() {
        XCTAssertEqual(SessionRef(host: "mini", name: "vivy").stringForm, "mini|vivy")
    }

    func testStringFormOfANilHostOmitsIt() {
        XCTAssertEqual(SessionRef(host: nil, name: "vivy").stringForm, "|vivy")
    }

    /// Two refs that are NOT equal must not collapse to the same string
    /// form — the property SwiftUI `.id()` keying depends on.
    func testStringFormDistinguishesDifferentHosts() {
        XCTAssertNotEqual(
            SessionRef(host: "mini", name: "vivy").stringForm,
            SessionRef(host: "guest", name: "vivy").stringForm)
    }

    /// The exact pair `stringForm`'s `|`-join would collide on if `host`
    /// went unvalidated: `host: "a|b", name: "c"` and `host: "a", name:
    /// "b|c"` both join to `"a|b|c"`. `SessionRef` itself is a plain struct
    /// and does not re-validate `host` — the guarantee lives upstream, at
    /// every place a host name enters config (`validateHostName`, run by
    /// `ThemeConfiguration.parseHosts`/`parseRail`/`parseCatalog`; see
    /// `SSHTargetTests.testHostNameRejectsThePipeSeparator`), so a `|`
    /// never reaches a `SessionRef.host` built from real config. This test
    /// pins the collision `stringForm` itself would produce if that
    /// upstream gate were ever removed — the reason the gate has to exist
    /// rather than a claim this struct enforces on its own.
    func testAHostContainingThePipeSeparatorFailsValidation() {
        XCTAssertThrowsError(try validateHostName("a|b"))

        let collidingA = SessionRef(host: "a|b", name: "c")
        let collidingB = SessionRef(host: "a", name: "b|c")
        XCTAssertNotEqual(collidingA, collidingB, "distinct refs by value")
        XCTAssertEqual(collidingA.stringForm, collidingB.stringForm,
                       "but stringForm collides — exactly why host must be validated before it reaches here")
    }

    // MARK: - owned(by:name:)

    func testOwnedByInheritsTheCrewsHost() {
        let crew = Crew(id: "ask", displayName: "Ask", host: "laptop")
        XCTAssertEqual(SessionRef.owned(by: crew, name: "ask--research"),
                       SessionRef(host: "laptop", name: "ask--research"))
    }

    func testOwnedByACrewWithNoHostFieldCarriesNil() {
        let crew = Crew(id: "ask", displayName: "Ask")
        XCTAssertEqual(SessionRef.owned(by: crew, name: "ask"), SessionRef(host: nil, name: "ask"))
    }

    // MARK: - orphaned(_:hosts:)

    /// An "OTHER SESSIONS" row recovers the config host NAME whose entry
    /// resolves to the actual target it was discovered on.
    func testOrphanedRecoversTheConfigHostName() {
        let laptop = HostEntry(name: "laptop", user: "operator", address: "10.0.0.5")
        let discovered = DiscoveredSession(name: "scratch", host: SSHTarget(user: "operator", host: "10.0.0.5"))
        XCTAssertEqual(SessionRef.orphaned(discovered, hosts: [laptop]),
                       SessionRef(host: "laptop", name: "scratch"))
    }

    /// With no `hosts` table at all, an orphan's ref carries `nil` — the
    /// same "implied default" every other ref resolves to in an
    /// unconfigured install.
    func testOrphanedWithNoHostsTableCarriesNil() {
        let discovered = DiscoveredSession(name: "scratch", host: TestHost.target)
        XCTAssertEqual(SessionRef.orphaned(discovered, hosts: []), SessionRef(host: nil, name: "scratch"))
    }

    // MARK: - localShell

    func testLocalShellIsReservedAndNeverEqualsAnOrdinaryRef() {
        XCTAssertNotEqual(SessionRef.localShell, SessionRef(host: nil, name: "vivy"))
        XCTAssertEqual(SessionRef.localShell, SessionRef(host: nil, name: "local:shell"))
    }

    /// `"local:shell"` contains a colon, which `validateTmuxSessionName`
    /// forbids — so it can never collide with a real, validated session
    /// name, the guarantee the reservation depends on.
    func testLocalShellsNameFailsSessionNameValidation() {
        XCTAssertThrowsError(try validateTmuxSessionName(SessionRef.localShell.name))
    }
}
