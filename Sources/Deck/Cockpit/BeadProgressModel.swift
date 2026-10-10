import Foundation

/// Drives the rail's bead-progress pane: the selected crew's bead title and
/// its progress fraction against the plan's last major revision
/// (`BeadProgress.compute`). One instance per `ContentView`, alongside
/// `CockpitModel`.
///
/// **KEPT SEPARATE FROM `CockpitModel` RATHER THAN FOLDED IN**, though it
/// follows that model's own polling discipline exactly. The two are gated
/// on different fields: the cockpit needs `Crew.project`, this needs
/// `Crew.bead`, and `CockpitResolution`'s own doc is explicit that a crew
/// may carry either without the other. Folding this in would mean
/// `CockpitModel.refresh` clearing bead state whenever a crew has no
/// project, which is exactly the crew this pane exists to still draw for.
///
/// FETCHES ON SELECTION CHANGE AND ON A SLOW TIMER, NOTHING MORE — mirrors
/// `CockpitModel.refreshInterval`'s own reasoning: a bead's `last_reviewed`
/// moves on the order of days, so a third fast poller would buy nothing.
@MainActor
final class BeadProgressModel: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var progress: BeadProgress.Result?

    private var lastFetched: Key?
    private var timerTask: Task<Void, Never>?

    private struct Key: Equatable {
        let host: SSHTarget
        let beadId: String
        /// The Library product epics are counted against — `Crew.project`,
        /// the same field `CockpitModel` reads for its own Course. `nil`
        /// when the crew names a bead and no project: the pane still draws
        /// the title, with no meter, the same "never invent a denominator"
        /// posture `BeadProgress.compute` takes for a missing revision.
        let product: String?
    }

    static let refreshInterval = Duration.seconds(600)

    init() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: BeadProgressModel.refreshInterval)
                guard !Task.isCancelled, let self, let key = self.lastFetched else { continue }
                await self.fetch(target: key.host, beadId: key.beadId, product: key.product)
            }
        }
    }

    deinit {
        timerTask?.cancel()
    }

    /// Points the model at a new crew's bead (or clears it). `beadId == nil`
    /// clears whatever was showing — the same "no selection, no stale read"
    /// rule `CockpitModel.refresh` follows — rather than leaving a prior
    /// crew's title on screen for a crew that has none.
    func refresh(target: SSHTarget?, beadId: String?, product: String?) async {
        guard let target, let beadId else {
            lastFetched = nil
            title = nil
            progress = nil
            return
        }
        let key = Key(host: target, beadId: beadId, product: product)
        guard key != lastFetched else { return }
        lastFetched = key
        await fetch(target: target, beadId: beadId, product: product)
    }

    private func fetch(target: SSHTarget, beadId: String, product: String?) async {
        do {
            let metadata = try await Task.detached {
                try WorkingCopyStore.fetchDocumentMetadata(target: target, kbId: beadId)
            }.value
            title = metadata.title
            progress = await computeProgress(target: target, product: product, revision: metadata.lastReviewed)
        } catch {
            // The metadata read failed outright (refused, unreachable, no
            // such document) — draw nothing rather than a stale title from
            // whatever crew was selected before, the same "field costs
            // itself" posture the rest of the Library reads take.
            title = nil
            progress = nil
        }
    }

    /// A failed epics fetch costs only the meter, never the title already
    /// set by `fetch` above — the pane still names the bead even when the
    /// second round trip comes back empty-handed.
    private func computeProgress(target: SSHTarget, product: String?, revision: String?) async -> BeadProgress.Result? {
        guard let product else { return nil }
        let fetched = try? await Task.detached {
            try LibraryClient.fetchEpics(target: target, product: product)
        }.value
        guard let epics = fetched else { return nil }
        return BeadProgress.compute(epics: epics, revision: revision)
    }
}
