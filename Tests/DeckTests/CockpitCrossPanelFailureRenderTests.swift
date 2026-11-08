import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Deck

/// Covers definition-of-done clause 7 of the cockpit epic
/// (issue_01M52P7CMZBGWAB6T1YWPG49PZ): "A test that makes one panel's source
/// fail shows that panel's failure in place while every other panel draws."
///
/// `CockpitModelTests.testFetchClearsAllWorkItemsOnFailureWithoutFailingTheRest`
/// is the only existing cross-panel test, and it fails only the PR-chip
/// join, at the model layer. These tests fail each of the five sources the
/// Cockpit column draws from — the Course, the corrections queue, the
/// proposed-epics region, the pull-request ladder, and the Sessions panel —
/// in turn, and render the five panels together as one column through
/// `NSHostingView`, so the assertion is on what actually draws, through the
/// column's shared layout, rather than only on model state. Each panel is
/// checked by the text it draws: its data, or its own failure line.
///
/// **No shared failure path was found.** `CockpitModel.fetch` already reads
/// the Course, the queue and the proposed epics through three independent
/// `async let`/catch pairs, one per source; the pull-request ladder and the
/// Sessions panel are supplied to `CockpitView` as plain parameters
/// (`pullRequests`, `sessions`), never through `CockpitModel` at all. Every
/// one of the five sources already fails on its own, so nothing in
/// `Sources/Deck` needed splitting for this test to pass.

// MARK: - Fixtures
//
// Free functions, not methods: `CockpitModel`'s `fetchCourse`/`fetchQueue`/
// `fetchEpics` seams are `@Sendable` closures, and a closure built from an
// instance method captures the (non-Sendable, main-actor) test case itself.

private let crossPanelProduct = "convivy-deck"

private func crossPanelEpic(_ id: String, maturity: String?) -> LibraryClient.Epic {
    LibraryClient.Epic(id: id, state: "open", resolution: nil, createdAt: nil, resolvedAt: nil,
                       title: "Epic \(id)", maturity: maturity)
}

private func goodCourse() -> LibraryClient.Course {
    LibraryClient.Course(id: "course_1", product: crossPanelProduct, title: "T",
                         entries: [LibraryClient.CourseEntry(id: "epic_A", title: "The epic")])
}

private func goodQueue() -> LibraryClient.CorrectionsQueue {
    LibraryClient.CorrectionsQueue(
        items: [LibraryClient.QueueItem(id: "cq_1", title: "A correction", state: "open")],
        total: 1, truncated: false, childParents: [:])
}

private func goodProposedEpics() -> [LibraryClient.Epic] {
    [crossPanelEpic("issue_P1", maturity: "proposed")]
}

private func goodSessionRow() -> CockpitView.SessionRow {
    let workingOn = SessionState.WorkingOn(text: "chasing the pagination bug", age: nil, stale: false, since: 120)
    return CockpitView.SessionRow(
        ref: SessionRef(host: nil, name: "deck-coder"), displayName: "deck-coder",
        state: SessionState(session: "deck-coder", phase: .working, alive: true, workingOn: workingOn))
}

/// The Sessions panel's own "failed" case: a session `railState.states`
/// carries no entry for, per the item's own wording — not a throw, since
/// this panel reads only already-polled local state and has no fetch of its
/// own to fail.
private func unreadableSessionRow() -> CockpitView.SessionRow {
    CockpitView.SessionRow(ref: SessionRef(host: nil, name: "deck-orphan"), displayName: "deck-orphan", state: nil)
}

private func goodPullRequestsPanel() -> CockpitView.PullRequestsPanel {
    CockpitView.PullRequestsPanel(
        result: .ladder([PRLadder.LadderResult(
            repo: "convivy/convivy-deck", number: 42, title: "A pull request", author: "agent-x",
            position: .readyToMerge, staleReviewCount: 0, updatedAt: "2026-10-01T00:00:00Z")], truncated: false),
        fetchError: nil, isLoading: false)
}

private func failingPullRequestsPanel() -> CockpitView.PullRequestsPanel {
    CockpitView.PullRequestsPanel(result: nil, fetchError: "ssh: timed out", isLoading: false)
}

private let courseFailure = LibraryClient.FetchError.unexpectedResponse("ssh: course unreachable")
private let queueFailure = LibraryClient.FetchError.unexpectedResponse("ssh: queue unreachable")
private let epicsFailure = LibraryClient.FetchError.unexpectedResponse("ssh: epics unreachable")

/// A model that has fetched once, with each of the three independent
/// sources `CockpitModel.fetch` reads answered by its own closure — the same
/// stubbing seam `CockpitModelTests` uses throughout.
@MainActor
private func makeModel(
    course: @escaping @Sendable (SSHTarget, String) throws -> LibraryClient.Course?,
    queue: @escaping @Sendable (SSHTarget, String) throws -> LibraryClient.CorrectionsQueue,
    epics: @escaping @Sendable (SSHTarget, String) throws -> [LibraryClient.Epic]
) async -> CockpitModel {
    let model = CockpitModel()
    model.fetchCourse = course
    model.fetchQueue = queue
    model.fetchEpics = epics
    model.fetchAllItems = { _, _ in [] }
    await model.refresh(target: TestHost.unreachableTarget, product: crossPanelProduct)
    return model
}

@MainActor
private func allGoodModel() async -> CockpitModel {
    await makeModel(
        course: { _, _ in goodCourse() },
        queue: { _, _ in goodQueue() },
        epics: { _, _ in goodProposedEpics() })
}

@MainActor
private func courseFailingModel() async -> CockpitModel {
    await makeModel(
        course: { _, _ in throw courseFailure },
        queue: { _, _ in goodQueue() },
        epics: { _, _ in goodProposedEpics() })
}

@MainActor
private func queueFailingModel() async -> CockpitModel {
    await makeModel(
        course: { _, _ in goodCourse() },
        queue: { _, _ in throw queueFailure },
        epics: { _, _ in goodProposedEpics() })
}

@MainActor
private func proposedEpicsFailingModel() async -> CockpitModel {
    await makeModel(
        course: { _, _ in goodCourse() },
        queue: { _, _ in goodQueue() },
        epics: { _, _ in throw epicsFailure })
}

/// Cyrillic and Greek letters that render identically to Latin ones,
/// mapped to the Latin letter OCR meant.
private let lookalikes: [Character: Character] = [
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P",
    "С": "C", "Т": "T", "Х": "X", "а": "a", "е": "e", "о": "o", "р": "p", "с": "c",
    "у": "y", "х": "x", "Α": "A", "Β": "B", "Ε": "E", "Η": "H", "Ι": "I", "Κ": "K",
    "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Χ": "X", "ο": "o",
]

private func foldLookalikes(_ text: String) -> String {
    String(text.map { lookalikes[$0] ?? $0 })
}

@MainActor
final class CockpitCrossPanelFailureRenderTests: XCTestCase {

    /// The five panels this test can make fail, rendered together as one
    /// column, and which it checks keep drawing when a sibling's source fails. `dispatched` and `checkout`
    /// are outside this item's scope (neither reads one of the five named
    /// sources) and are left out of `panelIDs` below.
    private let panelIDs = [
        CockpitView.sessionsPanelID, CockpitView.proposalsPanelID, CockpitView.coursePanelID,
        CockpitView.correctionsQueuePanelID, CockpitView.pullRequestsPanelID,
    ]

    // MARK: - Rendering the whole column

    /// What each panel draws when its source answers, as the text it shows.
    private let dataText: [String: String] = [
        CockpitView.sessionsPanelID: "chasing the pagination bug",
        CockpitView.proposalsPanelID: "Epic issue_P1",
        CockpitView.coursePanelID: "The epic",
        CockpitView.correctionsQueuePanelID: "A correction",
        CockpitView.pullRequestsPanelID: "A pull request",
    ]

    /// What each panel draws in place when its own source fails.
    private let failureText: [String: String] = [
        CockpitView.sessionsPanelID: "State unknown.",
        CockpitView.proposalsPanelID: "Could not reach proposals",
        CockpitView.coursePanelID: "Could not reach the Course",
        CockpitView.correctionsQueuePanelID: "Could not reach the queue",
        CockpitView.pullRequestsPanelID: "Could not reach pull requests",
    ]

    /// Renders the five panels TOGETHER, as one column, so the panels share
    /// the column's layout, its panel index and its frame bookkeeping the
    /// way they do in the app. The frame is tall enough that no panel sits
    /// below the fold, and no taller: at 1600 pt the five panels filled a
    /// quarter of the image and Vision skipped whole panels that had drawn
    /// correctly. Returns the lines of text read off the rendered image
    /// (`recognisedLines`).
    private func renderColumn(
        model: CockpitModel,
        sessions: [CockpitView.SessionRow], pullRequests: CockpitView.PullRequestsPanel
    ) async throws -> [String] {
        let view = CockpitView(
            model: model, unresolvedReason: nil, sessions: sessions, appearance: .light,
            onSelectCorrection: { _ in }, panelIDs: panelIDs, pullRequests: pullRequests
        )
        .background(Color(white: 0.98))
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 320, height: 900))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        defer { window.orderOut(nil) }
        // Three pixels per point whatever the display's own scale, so OCR
        // reads caption-size text reliably; at one pixel per point it
        // misread "pagination" as "padination".
        let scale = 3
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale,
            pixelsHigh: Int(host.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        return try recognisedLines(in: try XCTUnwrap(rep.cgImage))
    }

    /// The lines of text Vision reads off the rendered column: the text
    /// that actually drew, at the place it drew.
    private func recognisedLines(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Case-insensitive, because OCR does not keep case reliably: it reads
    /// "issue_P1" as "Issue_P1". Look-alike letters are folded to Latin
    /// first, because it also returns them: a full-suite run read
    /// "#42 A pull request" with a Cyrillic А and failed the match.
    private func draws(_ needle: String, in strings: [String]) -> Bool {
        strings.contains { foldLookalikes($0).range(of: needle, options: .caseInsensitive) != nil }
    }


    /// Renders the column once with exactly `failingPanel`'s source failed,
    /// and asserts that panel draws its own failure line in place of its
    /// data, while every other panel draws its data.
    ///
    /// The all-succeeding render is the control: it must show every panel's
    /// data and no failure line, or the text this test looks for is not
    /// what the panels draw and the failing case would prove nothing.
    private func assertOnlyOnePanelFails(
        failingPanel: String,
        goodModel: CockpitModel, failingModel: CockpitModel,
        goodSessions: [CockpitView.SessionRow], failingSessions: [CockpitView.SessionRow],
        goodPullRequests: CockpitView.PullRequestsPanel, failingPullRequests: CockpitView.PullRequestsPanel
    ) async throws {
        let good = try await renderColumn(model: goodModel, sessions: goodSessions, pullRequests: goodPullRequests)
        for id in panelIDs {
            XCTAssertTrue(draws(dataText[id]!, in: good), "control: \(id) did not draw its data. Saw: \(good)")
            XCTAssertFalse(draws(failureText[id]!, in: good), "control: \(id) drew a failure with every source up")
        }
        let failing = try await renderColumn(
            model: failingModel, sessions: failingSessions, pullRequests: failingPullRequests)
        for id in panelIDs {
            if id == failingPanel {
                XCTAssertTrue(draws(failureText[id]!, in: failing),
                              "\(id) did not draw its failure line in place. Saw: \(failing)")
                XCTAssertFalse(draws(dataText[id]!, in: failing), "\(id) still drew its data after its source failed")
            } else {
                XCTAssertTrue(draws(dataText[id]!, in: failing),
                              "\(id) stopped drawing when \(failingPanel)'s source failed. Saw: \(failing)")
                XCTAssertFalse(draws(failureText[id]!, in: failing),
                               "\(id) drew a failure line when only \(failingPanel)'s source failed")
            }
        }
    }

    // MARK: - Each source, failed in turn

    func testCourseFailureDrawsInPlaceAndEveryOtherPanelStillDraws() async throws {
        let goodModel = await allGoodModel()
        let failingModel = await courseFailingModel()
        try await assertOnlyOnePanelFails(
            failingPanel: CockpitView.coursePanelID,
            goodModel: goodModel, failingModel: failingModel,
            goodSessions: [goodSessionRow()], failingSessions: [goodSessionRow()],
            goodPullRequests: goodPullRequestsPanel(), failingPullRequests: goodPullRequestsPanel())
    }

    func testCorrectionsQueueFailureDrawsInPlaceAndEveryOtherPanelStillDraws() async throws {
        let goodModel = await allGoodModel()
        let failingModel = await queueFailingModel()
        try await assertOnlyOnePanelFails(
            failingPanel: CockpitView.correctionsQueuePanelID,
            goodModel: goodModel, failingModel: failingModel,
            goodSessions: [goodSessionRow()], failingSessions: [goodSessionRow()],
            goodPullRequests: goodPullRequestsPanel(), failingPullRequests: goodPullRequestsPanel())
    }

    func testProposedEpicsFailureDrawsInPlaceAndEveryOtherPanelStillDraws() async throws {
        let goodModel = await allGoodModel()
        let failingModel = await proposedEpicsFailingModel()
        try await assertOnlyOnePanelFails(
            failingPanel: CockpitView.proposalsPanelID,
            goodModel: goodModel, failingModel: failingModel,
            goodSessions: [goodSessionRow()], failingSessions: [goodSessionRow()],
            goodPullRequests: goodPullRequestsPanel(), failingPullRequests: goodPullRequestsPanel())
    }

    func testPullRequestLadderFailureDrawsInPlaceAndEveryOtherPanelStillDraws() async throws {
        let model = await allGoodModel()
        try await assertOnlyOnePanelFails(
            failingPanel: CockpitView.pullRequestsPanelID,
            goodModel: model, failingModel: model,
            goodSessions: [goodSessionRow()], failingSessions: [goodSessionRow()],
            goodPullRequests: goodPullRequestsPanel(), failingPullRequests: failingPullRequestsPanel())
    }

    func testSessionsFailureDrawsInPlaceAndEveryOtherPanelStillDraws() async throws {
        let model = await allGoodModel()
        try await assertOnlyOnePanelFails(
            failingPanel: CockpitView.sessionsPanelID,
            goodModel: model, failingModel: model,
            goodSessions: [goodSessionRow()], failingSessions: [unreadableSessionRow()],
            goodPullRequests: goodPullRequestsPanel(), failingPullRequests: goodPullRequestsPanel())
    }
}

/// The fold is what lets a look-alike OCR read still match. The control
/// shows a plain case-insensitive match misses the same line.
final class CockpitCrossPanelOCRFoldTests: XCTestCase {
    func testACyrillicLookalikeStillMatchesAfterFolding() {
        let read = "• #42 \u{0410} pull request"
        XCTAssertNil(read.range(of: "A pull request", options: .caseInsensitive), "control: the raw read misses")
        XCTAssertTrue(foldLookalikes(read).contains("A pull request"))
    }
}
