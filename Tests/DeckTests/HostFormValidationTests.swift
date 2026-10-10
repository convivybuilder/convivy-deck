import XCTest
@testable import Deck

/// `HostFormValidation` — the Hosts tab's add/edit sheet's own validation.
final class HostFormValidationTests: XCTestCase {
    func testAValidEntryIsBuilt() throws {
        let entry = try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "",
            existingHosts: [])
        XCTAssertEqual(entry, HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
    }

    func testFieldsAreTrimmed() throws {
        let entry = try HostFormValidation.makeEntry(
            name: "  guest  ", user: " guest ", address: " 1.2.3.4 ", crewsRoot: "",
            existingHosts: [])
        XCTAssertEqual(entry, HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
    }

    func testAnEmptyNameThrows() {
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "", user: "guest", address: "1.2.3.4", crewsRoot: "", existingHosts: [])) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .emptyName)
        }
    }

    func testANameWithAPipeThrows() {
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "a|b", user: "guest", address: "1.2.3.4", crewsRoot: "", existingHosts: [])) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .invalidName)
        }
    }

    func testADuplicateNameThrows() {
        let existing = [HostEntry(name: "guest", user: "guest", address: "1.1.1.1")]
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "guest", user: "someone", address: "2.2.2.2", crewsRoot: "",
            existingHosts: existing)) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .duplicateName)
        }
    }

    /// Editing a host without renaming it must not collide with itself.
    func testExcludingTheEntrysOwnNameLetsAnUnchangedNameThrough() throws {
        let existing = [HostEntry(name: "guest", user: "guest", address: "1.1.1.1")]
        let entry = try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "9.9.9.9", crewsRoot: "",
            existingHosts: existing, excludingName: "guest")
        XCTAssertEqual(entry.address, "9.9.9.9")
    }

    /// Renaming ONTO a different existing host's name is still refused even
    /// with an exclusion in play — the exclusion only protects the entry's
    /// own prior name.
    func testRenamingOntoADifferentHostsNameStillThrows() {
        let existing = [
            HostEntry(name: "guest", user: "guest", address: "1.1.1.1"),
            HostEntry(name: "office", user: "operator", address: "2.2.2.2"),
        ]
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "office", user: "guest", address: "1.1.1.1", crewsRoot: "",
            existingHosts: existing, excludingName: "guest")) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .duplicateName)
        }
    }

    func testAUserStartingWithADashThrows() {
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "evil", user: "-oProxyCommand=touch", address: "1.2.3.4", crewsRoot: "",
            existingHosts: [])) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .invalidUser)
        }
    }

    func testAnAddressStartingWithADashThrows() {
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "evil", user: "operator", address: "-oProxyCommand=touch", crewsRoot: "",
            existingHosts: [])) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .invalidAddress)
        }
    }

    func testAnEmptyCrewsRootIsNilRatherThanAnError() throws {
        let entry = try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "  ",
            existingHosts: [])
        XCTAssertNil(entry.crewsRoot)
    }

    func testARelativeCrewsRootThrows() {
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "relative/no-slash",
            existingHosts: [])) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .invalidCrewsRoot)
        }
    }

    func testAValidCrewsRootIsKept() throws {
        let entry = try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "~/work",
            existingHosts: [])
        XCTAssertEqual(entry.crewsRoot, "~/work")
    }

    // MARK: - Runbook link (CQ·124)

    func testAnEmptyRunbookLinkIsNilRatherThanAnError() throws {
        let entry = try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "", runbookLink: "  ",
            existingHosts: [])
        XCTAssertNil(entry.runbookLink)
    }

    func testAValidHttpsRunbookLinkIsKept() throws {
        let entry = try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "",
            runbookLink: "https://example.com/runbook", existingHosts: [])
        XCTAssertEqual(entry.runbookLink, "https://example.com/runbook")
    }

    func testAValidKBIdRunbookLinkIsKept() throws {
        let entry = try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "",
            runbookLink: "shipwright/runbooks/log-back-in", existingHosts: [])
        XCTAssertEqual(entry.runbookLink, "shipwright/runbooks/log-back-in")
    }

    func testAnHttpRunbookLinkThrows() {
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "",
            runbookLink: "http://example.com/runbook", existingHosts: [])) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .invalidRunbookLink)
        }
    }

    func testAnUnrecognisedSchemeRunbookLinkThrows() {
        XCTAssertThrowsError(try HostFormValidation.makeEntry(
            name: "guest", user: "guest", address: "1.2.3.4", crewsRoot: "",
            runbookLink: "javascript:alert(1)", existingHosts: [])) { error in
            XCTAssertEqual(error as? HostFormValidation.FieldError, .invalidRunbookLink)
        }
    }

    // MARK: - Error messages are pinned so wording is a test failure, not a guess

    func testEveryFieldErrorHasItsOwnMessage() {
        let errors: [HostFormValidation.FieldError] = [
            .emptyName, .invalidName, .duplicateName, .invalidUser, .invalidAddress, .invalidCrewsRoot,
            .invalidRunbookLink,
        ]
        let messages = Set(errors.map { HostFormValidation.errorMessage($0) })
        XCTAssertEqual(messages.count, errors.count, "every case must read distinctly")
    }
}
