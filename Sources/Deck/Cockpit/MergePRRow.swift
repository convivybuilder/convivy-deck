import AppKit
import SwiftUI

/// The merge and close affordance for one pull-request row —
/// `issue_01M1HQMDZ8TG2KVK7JG6P7YK7T`. A standalone view, the same split
/// `MergeRefusalRow`'s own doc names ("the later item that presses merge
/// mounts this wherever its result needs to draw"): this file is where that
/// mounting happens, in `CockpitView.pullRequestRow`.
///
/// **A press is one human click on a confirmation that names the pull
/// request and its short head.** Nothing here presses either button
/// programmatically — no auto-merge, no merge-when-green, no retry; every
/// path to `onConfirmMerge`/`onConfirmClose` passes through SwiftUI's own
/// `.confirmationDialog`, which only a click can satisfy.
struct MergePRRow: View {
    let row: PRLadder.LadderResult
    let state: MergePressState
    let appearance: Appearance
    let advice: PreMergeAdviceResult
    /// `nil` when this machine serves sessions — 0003's "the row offers no
    /// merge button and links to the pull request on github.com instead."
    let servedSessionsReason: MergeRefusal.ServesSessionsReason?
    /// Whether a served-sessions refusal offers to remove a pasted token.
    var pastedTokenStored = false

    var onRemoveToken: () -> Void = {}
    var onBeginMerge: () -> Void = {}
    var onBeginClose: () -> Void = {}
    var onConfirmMerge: () -> Void = {}
    var onConfirmClose: () -> Void = {}
    var onCancel: () -> Void = {}
    var onSaveToken: (String) -> Void = { _ in }

    @State private var pastedToken = ""

    private var surface: RGB { CockpitView.resolvedIndexSurface(appearance: appearance) }
    private var secondaryInk: AnyShapeStyle { CockpitView.secondaryInkStyle(on: surface) }

    private var shortHead: String? {
        guard let headSha = row.headSha else { return nil }
        return String(headSha.prefix(7))
    }

    private var isTerminal: Bool {
        PRLadderRow.present(row.position).isTerminal
    }

    /// The press already merged or closed this pull request, so the row
    /// offers nothing more while the ladder catches up.
    private var pressSettled: Bool {
        switch state {
        case .reported, .closed: return true
        default: return false
        }
    }

    private var canOfferMergeButton: Bool {
        servedSessionsReason == nil && !pressSettled && row.position.offersMerge && shortHead != nil
    }

    private var canOfferCloseButton: Bool {
        servedSessionsReason == nil && !pressSettled && !isTerminal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let servedSessionsReason {
                servedSessionsLink(servedSessionsReason)
            } else {
                controls
            }
            stateContent
            Text(PreMergeAdvice.line(advice))
                .frameFont(.caption)
                .foregroundStyle(secondaryInk)
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if canOfferMergeButton, let shortHead {
                Button("Merge \(shortHead)") { onBeginMerge() }
                    .disabled(state == .working)
                    .confirmationDialog(
                        "Merge pull request #\(row.number) at \(shortHead)?",
                        isPresented: Binding(
                            get: { state == .confirmingMerge },
                            set: { presented in if !presented { onCancel() } }),
                        titleVisibility: .visible
                    ) {
                        Button("Merge #\(row.number) at \(shortHead)") { onConfirmMerge() }
                        Button("Cancel", role: .cancel) { onCancel() }
                    }
            }
            if canOfferCloseButton {
                Button("Close without merging") { onBeginClose() }
                    .disabled(state == .working)
                    .confirmationDialog(
                        "Close pull request #\(row.number) without merging?",
                        isPresented: Binding(
                            get: { state == .confirmingClose },
                            set: { presented in if !presented { onCancel() } }),
                        titleVisibility: .visible
                    ) {
                        Button("Close #\(row.number)", role: .destructive) { onConfirmClose() }
                        Button("Cancel", role: .cancel) { onCancel() }
                    }
            }
            if state == .working {
                ProgressView().controlSize(.mini)
            }
        }
        .frameFont(.caption)
    }

    private func servedSessionsLink(_ reason: MergeRefusal.ServesSessionsReason) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MergeRefusalRow(refusal: .servesSessions(reason), appearance: appearance)
            if let url = PRLadderRow.githubURL(repo: row.repo, number: row.number) {
                Text("Open #\(row.number) on GitHub")
                    .frameFont(.caption)
                    .underline()
                    .onTapGesture { NSWorkspace.shared.open(url) }
            }
            removeTokenOffer
        }
    }

    @ViewBuilder
    private var removeTokenOffer: some View {
        if pastedTokenStored {
            Button("Remove the saved GitHub token") { onRemoveToken() }
                .frameFont(.caption)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle, .confirmingMerge, .confirmingClose, .working:
            EmptyView()
        case .noCredential:
            VStack(alignment: .leading, spacing: 4) {
                Text("No GitHub credential found. Sign in with \u{2018}gh\u{2019}, or paste a token below.")
                    .frameFont(.caption)
                    .foregroundStyle(AnyShapeStyle(Color(ThemeRecipe.warningInk(on: surface))))
                HStack(spacing: 6) {
                    SecureField("Personal access token", text: $pastedToken)
                        .textFieldStyle(.roundedBorder)
                        .frameFont(.caption)
                    Button("Save") {
                        guard !pastedToken.isEmpty else { return }
                        onSaveToken(pastedToken)
                        pastedToken = ""
                    }
                    .disabled(pastedToken.isEmpty)
                }
            }
        case .refused(.servesSessions(let reason)):
            // With a display reason set, `servedSessionsLink` already draws
            // this refusal and the offer.
            if servedSessionsReason == nil {
                MergeRefusalRow(refusal: .servesSessions(reason), appearance: appearance)
                removeTokenOffer
            }
        case .refused(let refusal):
            MergeRefusalRow(refusal: refusal, appearance: appearance)
        case .reported(let outcome):
            Text(MergePRRow.reportedLine(outcome))
                .frameFont(.caption)
                .foregroundStyle(secondaryInk)
        case .closed:
            Text("Closed without merging.")
                .frameFont(.caption)
                .foregroundStyle(secondaryInk)
        }
    }

    /// `MergeReportOutcome`'s own drawn line — the three answers the item
    /// names: "closed, waiting on a lease holder, or the report failed,
    /// which leaves the merge itself reported as done on GitHub."
    static func reportedLine(_ outcome: MergeReportOutcome) -> String {
        switch outcome {
        case .closed:
            return "Merged. The work item closed."
        case .waitingOnLeaseHolder:
            return "Merged. Waiting on another holder's lease before the work item closes."
        case .reportFailed(let reason):
            return "Merged on GitHub, but the report to the Keel failed (\(reason)). " +
                "The merge itself is already done."
        }
    }
}
