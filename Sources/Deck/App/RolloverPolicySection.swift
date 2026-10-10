import SwiftUI

/// One machine's rollover policy, read and edited from that host's detail in
/// Settings › Hosts (epic `issue_01M1S2Y2FMEM6WAKPYZ8YX4VMN`: "the operator
/// tunes it"). Per host, because the policy is one file per machine
/// (`~/.config/convivy/rollover.json`), re-read by the machine's hook on every
/// firing, so a change takes effect on running sessions with nothing restarted.
///
/// THE MACHINE STAYS THE DECIDER. These fields set the limits its hook
/// evaluates; nothing here decides that a session rolls over
/// (`platform/decisions/0069-a-co-session-rolls-itself-over-before-it-runs-out-of-context`).
///
/// WHETHER THE MACHINE ACTS IS SHOWN, NOT OFFERED. The epic's specification
/// names three limits for the operator to set: where looking starts, how hard
/// a session tries, and when it takes a poor moment. Switching from watching
/// to acting is the platform's step, taken once the unattended rollover path
/// is safe, so Deck never sends `mode`.
struct RolloverPolicySection: View {
    let host: HostEntry

    @State private var policy: SessionState.Rollover.Policy?
    @State private var message: String?
    @State private var isBusy = false
    /// One counter PER FIELD, bumped after that field's commit attempt, so the
    /// field re-seeds from `policy` rather than keeping text the machine
    /// refused (`CommittingField` only re-seeds when its `text` changes). Per
    /// field because the counter is part of the field's `.id`: a single shared
    /// counter tore down all three fields whenever any one committed, throwing
    /// away whatever was being typed into a sibling during the round trip.
    @State private var revisions: [SessionAgent.RolloverPolicyField: Int] = [:]
    /// Which host the section's current reading is for. Read back after every
    /// remote call, from `@State` storage rather than from the call's captured
    /// `host`, so an answer that lands after the selection has moved to another
    /// host is dropped instead of shown as the new host's.
    @State private var readingHost = ""

    private var hostKey: String { "\(host.name)|\(host.user)|\(host.address)" }
    private var target: SSHTarget { SSHTarget(user: host.user, host: host.address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rollover")
                .font(.headline)
            Text("Before a session on this machine runs out of context, it hands off and carries on in a fresh session. The machine decides when; these are the limits it uses.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let policy {
                field("Start looking at:", .seekPercent, value: policy.seekPercent,
                      prompt: "70", unit: "% of context")
                field("Roll over regardless at:", .floorPercent, value: policy.floorPercent,
                      prompt: "Not set", unit: "% of context")
                field("Stop looking after:", .seekCallCap, value: policy.seekCallCap.map(Double.init),
                      prompt: "Not set", unit: "model calls")
                LabeledContent("Acting on it:") {
                    Text(RolloverPolicySection.modeDescription(policy.mode))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Leave a limit blank to keep it unset. Whether the machine acts is changed on the machine, not here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isBusy {
                Text("Reading this machine\u{2019}s policy\u{2026}")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: hostKey) { await load() }
    }

    private func field(_ label: String, _ field: SessionAgent.RolloverPolicyField,
                       value: Double?, prompt: String, unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                CommittingField(text: RolloverPolicySection.fieldText(value), prompt: prompt,
                                onCommit: { commit(field, $0, current: value) })
                    .frame(width: 64)
                    .id("rollover-\(host.name)-\(field.rawValue)-\(revisions[field, default: 0])")
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        let key = hostKey
        readingHost = key
        policy = nil
        message = nil
        isBusy = true
        let target = self.target
        let result = await Task.detached { RolloverPolicySection.call(target: target, updates: []) }.value
        guard readingHost == key else { return }
        isBusy = false
        apply(result, whenMalformed: "This machine doesn\u{2019}t report a rollover policy.")
    }

    private func commit(_ field: SessionAgent.RolloverPolicyField, _ text: String, current: Double?) {
        switch RolloverPolicySection.parse(text, field: field) {
        case .invalid(let reason):
            message = reason
            revisions[field, default: 0] += 1
        case .value(let value):
            guard value != current else {
                revisions[field, default: 0] += 1
                return
            }
            let key = hostKey
            let target = self.target
            let update = SessionAgent.RolloverPolicyUpdate(field: field, value: value)
            isBusy = true
            Task {
                let result = await Task.detached {
                    RolloverPolicySection.call(target: target, updates: [update])
                }.value
                // The selection moved to another host while this was in flight.
                // The edit still landed on the host it was made for; its answer
                // just no longer describes what this section is showing.
                guard readingHost == key else { return }
                isBusy = false
                apply(result, whenMalformed: "This machine\u{2019}s answer couldn\u{2019}t be read, so the change may not have been saved.")
                revisions[field, default: 0] += 1
            }
        }
    }

    private func apply(_ result: CallResult, whenMalformed: String) {
        switch result {
        case .outcome(.policy(let latest)):
            policy = latest
            message = nil
        case .outcome(.refused(let reason)):
            message = RolloverPolicySection.readableRefusal(reason)
        case .outcome(.malformed):
            message = whenMalformed
        case .unreachable(let error):
            message = "Couldn\u{2019}t reach this machine: \(error)"
        }
    }

    enum CallResult: Equatable {
        case outcome(SessionAgent.RolloverPolicyOutcome)
        case unreachable(String)
    }

    nonisolated static func call(target: SSHTarget,
                                 updates: [SessionAgent.RolloverPolicyUpdate]) -> CallResult {
        do { return .outcome(try SessionAgent.rolloverPolicy(target: target, updates: updates)) }
        catch { return .unreachable("\(error)") }
    }

    // MARK: - Pure pieces, pinned by `RolloverPolicyTests`

    enum Input: Equatable {
        /// A value to send. `nil` unsets a limit.
        case value(Double?)
        /// Refused before anything is sent, with a sentence saying why.
        case invalid(String)
    }

    /// What a field's typed text means. TEXT NEVER REACHES ARGV: it is parsed
    /// into a finite number here, and `SessionAgent.policyArgument` formats
    /// that number, so nothing a person types is passed to the remote shell.
    nonisolated static func parse(_ text: String, field: SessionAgent.RolloverPolicyField) -> Input {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) }
        if trimmed.isEmpty {
            return field == .seekPercent
                ? .invalid("Where looking starts can\u{2019}t be blank. Enter a percentage from 1 to 99.")
                : .value(nil)
        }
        guard let number = Double(trimmed), number.isFinite else { return .invalid("Enter a number.") }
        switch field {
        case .seekPercent:
            return (1...99).contains(number) ? .value(number) : .invalid("Enter a percentage from 1 to 99.")
        case .floorPercent:
            return (1...100).contains(number) ? .value(number) : .invalid("Enter a percentage from 1 to 100.")
        case .seekCallCap:
            return number >= 1 && number == number.rounded() && number <= 100_000
                ? .value(number) : .invalid("Enter a whole number of calls, 1 or more.")
        }
    }

    /// A value as its field shows it: blank when unset, no trailing `.0`.
    nonisolated static func fieldText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    /// The machine's refusal, with its policy key names replaced by the
    /// names this pane uses.
    nonisolated static func readableRefusal(_ raw: String) -> String {
        raw.replacingOccurrences(of: "seek_call_cap", with: "the call limit")
            .replacingOccurrences(of: "floor_pct", with: "the roll-over-regardless point")
            .replacingOccurrences(of: "seek_pct", with: "where looking starts")
    }

    nonisolated static func modeDescription(_ mode: String?) -> String {
        switch mode {
        case "observe": return "Not yet. The machine records when a session would roll over, but doesn\u{2019}t act."
        case "enforce": return "Yes. Sessions roll over on their own."
        case let other?: return "Unknown (\(other))."
        case nil: return "Unknown."
        }
    }
}
