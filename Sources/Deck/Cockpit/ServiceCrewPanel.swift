import SwiftUI

/// The minimal rest-state panel for a `.service`-shaped crew
/// (`RestStateResolution.Shape.service`) — ask, cfo, ea today.
///
/// **SERVICE CREWS ARE BLACK BOXES.** No element here may read their
/// content; this draws only what the platform already knows about a
/// dispatch — the same `AgentRun` fields the steward's board draws in its
/// Dispatched panel, scoped to this crew's own runs rather than the fleet's.
/// Nothing else. The steward-board proposal's own words: "inventing a
/// fuller panel for them would manufacture content out of exactly the
/// store their wall exists to keep empty."
struct ServiceCrewPanel: View {
    /// `CockpitResolution.restStateUnresolvedReason`: the session-level
    /// checks only, never the course cockpit's "set a project" message.
    let unresolvedReason: String?
    let agentRuns: [SessionState.AgentRun]?
    let appearance: Appearance
    /// The Builder Default ground this panel is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    private var secondaryInk: AnyShapeStyle { CockpitView.secondaryInkStyle(on: statusGround) }
    var accent: RGB? = nil
    var onSelectRun: ((String) -> Void)? = nil
    var openRunId: String? = nil

    /// The band is neutral, like the Cockpit's: a service crew has no project
    /// and so no place line, and nothing about it is one session's colour.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnBand(title: "Crew", icon: "square.grid.2x2.fill", place: nil,
                       colours: .neutral(appearance, ground: statusGround)) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let unresolvedReason {
                        Text(unresolvedReason)
                            .frameFont(.label)
                            .foregroundStyle(secondaryInk)
                            .padding(.top, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            // ONE HONEST LINE, replacing the old "set a project"
                            // instruction that misdiagnosed a crew with no
                            // project to set — see the steward-board proposal's
                            // "A service panel" section.
                            Text("This crew follows no Course.")
                                .frameFont(.label)
                                .foregroundStyle(secondaryInk)
                            Divider().padding(.vertical, 4)
                            DispatchedPanelSection(
                                title: "Dispatched", agentRuns: agentRuns,
                                appearance: appearance, accent: accent,
                                onSelectRun: onSelectRun, openRunId: openRunId)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                }
            }
        }
    }

/// `ServiceCrewPanel`'s Dispatched panel body: this crew's own runs, drawn
/// through `CockpitView`'s row and sanitisation helpers so a service crew's
/// run row matches the cockpit's and the steward's board's.
///
/// `fileprivate`, not `private`, so it stays a separate type from
/// `ServiceCrewPanel` rather than a nested one.
fileprivate struct DispatchedPanelSection: View {
    let title: String
    let agentRuns: [SessionState.AgentRun]?
    let appearance: Appearance
    /// The Builder Default ground this panel is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    let accent: RGB?
    private var secondaryInk: AnyShapeStyle { CockpitView.secondaryInkStyle(on: statusGround) }
    var onSelectRun: ((String) -> Void)? = nil
    var openRunId: String? = nil

    private var resolvedAccent: RGB { accent ?? SessionPaneView.neutralAccent(appearance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).frameFont(.body).fontWeight(.semibold)
                Spacer()
                if let agentRuns {
                    Text("\(agentRuns.count)").frameFont(.label).foregroundStyle(secondaryInk)
                }
            }
            if let agentRuns {
                if agentRuns.isEmpty {
                    Text("No agents in flight.")
                        .frameFont(.label).foregroundStyle(secondaryInk)
                } else {
                    ForEach(CockpitView.sortedAgentRuns(agentRuns), id: \.id) { run in
                        runRow(run)
                    }
                }
            } else {
                Text("This host doesn't report agent runs yet.")
                    .frameFont(.label).foregroundStyle(secondaryInk)
            }
            // ALWAYS DRAWN — see `CockpitView.crewStatsContent`'s own doc
            // for why this reads as furniture rather than an alert.
            Text("Runs started through the Task tool aren't tracked here.")
                .frameFont(.caption).foregroundStyle(secondaryInk)
        }
    }

    /// Identical grammar to `CockpitView.agentRunRow`, reusing every
    /// sanitisation and formatting helper that view exposes
    /// (`sanitizedAgentField`, `agentRunTrailingMetadata`, `taskGloss`,
    /// `agentRunHelpText`, `glyphInk`) rather than a second copy of the
    /// logic. Only the layout code is parallel; the decisions it renders
    /// all come from the one shared implementation.
    private func runRow(_ run: SessionState.AgentRun) -> some View {
        // Same leaf-level `.help` placement as `CockpitView.agentRunRow`,
        // and the same reason: see that function's doc.
        let helpText = CockpitView.agentRunHelpText(run) ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: CockpitView.RowTreatment.inProgress.glyphName)
                .frameFont(.icon)
                .foregroundStyle(CockpitView.glyphInk(
                    treatment: .inProgress, accent: resolvedAccent, appearance: appearance,
                    ground: statusGround))
                .frame(width: 12, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CockpitView.sanitizedAgentField(run.agent))
                        .frameFont(.label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .help(helpText)
                    Spacer(minLength: 0)
                    if let trailing = CockpitView.agentRunTrailingMetadata(run, now: Date()) {
                        Text(trailing)
                            .frameFont(.caption)
                            .foregroundStyle(secondaryInk)
                            .monospacedDigit()
                            .fixedSize()
                            .help(helpText)
                    }
                }
                if let task = run.task {
                    Text(CockpitView.taskGloss(task))
                        .frameFont(.caption)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(helpText)
                }
            }
        }
        .runRowSelection(runId: run.runId, openRunId: openRunId, onSelectRun: onSelectRun)
    }
}
