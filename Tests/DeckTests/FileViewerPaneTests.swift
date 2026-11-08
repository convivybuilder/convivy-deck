import XCTest
@testable import Deck

/// `FileViewerModel`'s refresh behaviour (CQ·185) — `fetchFile`/`renderFile`
/// are seams so these run with no ssh round trip, the same shape
/// `ItemDetailModel`'s tests use.
final class FileViewerPaneTests: XCTestCase {

    private let ref = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/notes.md")

    // MARK: - Refresh re-runs the load for the same ref

    /// A refresh re-fetches and re-renders rather than reusing what is
    /// cached — the fetch runs again, and a changed answer reaches `html`.
    @MainActor
    func testRefreshReFetchesTheSameRefAndPicksUpAChange() async {
        let model = FileViewerModel()
        let fetchCount = FetchCounter()
        model.fetchFile = { _, _ in
            let count = fetchCount.increment()
            return (URL(fileURLWithPath: "/tmp/notes.md"), Data("version \(count)".utf8))
        }
        model.renderFile = { _, data, _, _, _ in String(data: data, encoding: .utf8) ?? "" }

        await model.load(ref: ref, appearance: .light, target: TestHost.target)
        XCTAssertEqual(model.html, "version 1")

        await model.load(ref: ref, appearance: .light, target: TestHost.target)
        XCTAssertEqual(fetchCount.value, 2)
        XCTAssertEqual(model.html, "version 2")
    }

    /// Switching to a different ref is not a refresh: it clears to the
    /// loading page first rather than keeping the old file's content —
    /// `PaneLoadIdentity`'s own doc on why a ref change must refire.
    @MainActor
    func testADifferentRefIsNotTreatedAsARefresh() async {
        let model = FileViewerModel()
        model.fetchFile = { ref, _ in (URL(fileURLWithPath: "/tmp/notes.md"), Data("first".utf8)) }
        model.renderFile = { _, data, _, _, _ in String(data: data, encoding: .utf8) ?? "" }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)
        XCTAssertEqual(model.html, "first")

        let otherRef = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/other.md")
        model.fetchFile = { _, _ in throw WorkingCopyStore.FetchError.unexpectedResponse("boom") }
        await model.load(ref: otherRef, appearance: .light, target: TestHost.target)
        // A fresh ref that fails shows the error page, not the previous
        // file's content, since there was nothing cached for THIS ref.
        XCTAssertTrue(model.html.contains("error"))
        XCTAssertNil(model.refreshError)
    }

    // MARK: - A failed refresh keeps the last content on screen

    /// A failed refresh leaves `html` exactly as it was and reports the
    /// failure separately, rather than replacing the viewer with an error
    /// page the way a failed first load does.
    @MainActor
    func testAFailedRefreshKeepsTheLastContentAndReportsTheFailure() async {
        let model = FileViewerModel()
        model.fetchFile = { _, _ in (URL(fileURLWithPath: "/tmp/notes.md"), Data("first".utf8)) }
        model.renderFile = { _, data, _, _, _ in String(data: data, encoding: .utf8) ?? "" }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)
        XCTAssertEqual(model.html, "first")

        model.fetchFile = { _, _ in throw WorkingCopyStore.FetchError.unexpectedResponse("boom") }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)

        XCTAssertEqual(model.html, "first")
        XCTAssertNotNil(model.refreshError)
    }

    /// A refresh that fails during RENDER (the fetch itself succeeded)
    /// keeps the last content too — the fetch having landed a fresh copy
    /// does not matter if nothing can be shown from it yet.
    @MainActor
    func testAFailedRefreshRenderAlsoKeepsTheLastContent() async {
        let model = FileViewerModel()
        model.fetchFile = { _, _ in (URL(fileURLWithPath: "/tmp/notes.md"), Data("first".utf8)) }
        model.renderFile = { _, data, _, _, _ in String(data: data, encoding: .utf8) ?? "" }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)
        XCTAssertEqual(model.html, "first")

        model.renderFile = { _, _, _, _, _ in throw WorkingCopyStore.FetchError.unexpectedResponse("render boom") }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)

        XCTAssertEqual(model.html, "first")
        XCTAssertNotNil(model.refreshError)
    }

    /// A SUCCESSFUL refresh clears any refusal a previous failed one left.
    @MainActor
    func testASuccessfulRefreshClearsAPriorRefreshError() async {
        let model = FileViewerModel()
        model.fetchFile = { _, _ in (URL(fileURLWithPath: "/tmp/notes.md"), Data("first".utf8)) }
        model.renderFile = { _, data, _, _, _ in String(data: data, encoding: .utf8) ?? "" }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)

        model.fetchFile = { _, _ in throw WorkingCopyStore.FetchError.unexpectedResponse("boom") }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)
        XCTAssertNotNil(model.refreshError)

        model.fetchFile = { _, _ in (URL(fileURLWithPath: "/tmp/notes.md"), Data("second".utf8)) }
        await model.load(ref: ref, appearance: .light, target: TestHost.target)
        XCTAssertEqual(model.html, "second")
        XCTAssertNil(model.refreshError)
    }

    // MARK: - PaneLoadIdentity

    /// The refresh button's whole mechanism: bumping the token changes the
    /// identity `.task(id:)` keys on even though `ref`/`target` did not
    /// move, which is what refires the load.
    func testRefreshTokenChangesTheLoadIdentity() {
        let a = PaneLoadIdentity(ref: ref, target: TestHost.target, refreshToken: 0)
        let b = PaneLoadIdentity(ref: ref, target: TestHost.target, refreshToken: 1)
        XCTAssertNotEqual(a, b)
    }

    /// `EditorPane` builds this with no token at all — the default keeps
    /// every such call site compiling and behaving as before.
    func testOmittingTheTokenDefaultsToZero() {
        XCTAssertEqual(PaneLoadIdentity(ref: ref, target: TestHost.target),
                       PaneLoadIdentity(ref: ref, target: TestHost.target, refreshToken: 0))
    }
}

/// A locked counter so `fetchFile` — `@Sendable`, and called from inside
/// `Task.detached` — can count its own calls without the compiler reading a
/// plain captured `var` as a data race.
private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
