import Foundation

/// How a dispatched run's model was chosen, as the run register's `GET /runs`
/// serves it in `model_source`.
///
/// **SIX VALUES, AND ANY OTHER IS `nil`.** `init?(wire:)` refuses a string it
/// does not know rather than mapping it to a default, so a seventh value
/// added upstream draws no mark instead of borrowing the wrong one. The
/// register serves the field per run and `null` for both fields when a run's
/// meta is unreadable; both land here as "no source".
enum RunModelSource: Equatable {
    /// The roster's own default. Draws nothing.
    case roster
    /// A `--model` typed at dispatch by a person at a terminal — claimed by
    /// the absence of `CLAUDECODE` in the dispatching process's own
    /// environment, not proven.
    case overrideTyped
    /// A `--model` a co passed at dispatch — the dispatching process's own
    /// environment carried `CLAUDECODE`, so an agent session chose it.
    case overrideCo
    /// Set on the work item through the Library's reserved route. That route
    /// attests an approved client, not a verified person, so any text naming
    /// who chose it says "claimed".
    case overrideItem
    /// An override recorded under the old `operator_override` label, before
    /// this three-way split existed. Nobody recorded who chose it, so no
    /// label here may say "operator" or "typed" for it.
    case overrideUnattributed
    /// The model that ran differs from the one the dispatch resolved, and the
    /// difference was not an override. Nobody chose it.
    case failover

    init?(wire: String) {
        switch wire {
        case "roster": self = .roster
        case "override-typed": self = .overrideTyped
        case "override-co": self = .overrideCo
        case "override-item": self = .overrideItem
        case "override-unattributed": self = .overrideUnattributed
        case "failover": self = .failover
        default: return nil
        }
    }
}

/// What the run register says about one run: the model that actually ran and
/// how it was chosen. Each field is independently optional, so a register
/// that serves one and not the other, or a value this build does not know,
/// costs that field and never the row.
struct RunModelChoice: Equatable {
    var model: String?
    var source: RunModelSource?
    /// The model the dispatch resolved before any fail-over (`model_resolved`,
    /// issue_01M3BBV11BRVYPVMJ903YBNH36). Only read to name what a fail-over
    /// fell back FROM; absent until the register serves it.
    var modelResolved: String? = nil
    /// The full dispatch instruction (`task`). The register serves it whole;
    /// session-agent's own `agent_runs[].task` is cut near 500 characters, so
    /// this is the only place Deck can read the complete text. Absent for a
    /// private crew's run, which the register omits.
    var task: String? = nil
}

/// The one thing the rail draws for a run that is off its roster model.
enum RunModelMarkKind: Equatable {
    /// Someone chose the model: `override-typed`, `override-co`,
    /// `override-item` and `override-unattributed` share it.
    case override
    /// Nobody chose the model. Its own glyph and ink, because the two mean
    /// different things to the person reading the rail.
    case failover
}

/// A session row's run-model mark: which glyph draws, and the hover text.
struct RunModelMark: Equatable {
    let kind: RunModelMarkKind
    let help: String

    /// The mark a single source draws, or nil for `roster`, an unknown value
    /// and a missing one.
    static func kind(for source: RunModelSource?) -> RunModelMarkKind? {
        switch source {
        case .overrideTyped, .overrideCo, .overrideItem, .overrideUnattributed: return .override
        case .failover: return .failover
        case .roster, nil: return nil
        }
    }

    /// One run's hover sentence, in plain words. `nil` when the run draws no
    /// mark. `override-item` says the choice was claimed, never verified:
    /// the reserved route vouches for a client, not for whoever it names.
    static func sentence(agent: String?, choice: RunModelChoice) -> String? {
        guard kind(for: choice.source) != nil else { return nil }
        let model = choice.model.map { CockpitView.sanitizedAgentField($0) } ?? "an unreported model"
        let subject = agent.map { "\(CockpitView.sanitizedAgentField($0)) ran on \(model)" } ?? "A run is on \(model)"
        switch choice.source {
        case .overrideTyped:
            return "\(subject), typed as a model override at dispatch instead of the roster default."
        case .overrideCo:
            return "\(subject), overridden by a co that passed --model at dispatch."
        case .overrideItem:
            return "\(subject), set on the work item as an override. Who set it is claimed, not verified."
        case .overrideUnattributed:
            return "\(subject), overridden at dispatch. Who chose it was not recorded."
        case .failover:
            return "\(subject) after a fail-over. Nobody chose this model."
        default:
            return nil
        }
    }

    /// `runs` with each one's `modelSource` set from `register` by `run_id`.
    /// A run with no id, or none in the register, keeps nil.
    static func withModelSources(_ runs: [SessionState.AgentRun],
                                 register: [String: RunModelChoice]) -> [SessionState.AgentRun] {
        runs.map { run in
            var run = run
            let choice = run.runId.flatMap { register[$0] }
            run.modelSource = choice?.source
            run.modelResolved = choice?.modelResolved
            run.fullTask = choice?.task
            return run
        }
    }

    /// The parenthetical the Dispatched line puts after a run's model, as
    /// in "haiku 4.5 (typed override)" (the operator, 2026-09-24; relabeled off the
    /// old unqualified "operator override", issue_01M3NTZP9W8WEYWVERW2F9NARP —
    /// only a verified operator value may say "operator" unqualified, and
    /// none exists yet). nil for `roster` and for an unknown source, so a run
    /// on its roster model reads exactly as before. A fail-over reads
    /// "failover from <model>" when the register serves `model_resolved`,
    /// and plain "failover" when it doesn't.
    static func dispatchedQualifier(for source: RunModelSource?, resolved: String? = nil) -> String? {
        switch source {
        case .overrideTyped: return "typed override"
        case .overrideCo: return "co override"
        case .overrideItem: return "set on the item"
        case .overrideUnattributed: return "override (source unknown)"
        case .failover:
            guard let resolved, !resolved.isEmpty else { return "failover" }
            return "failover from \(CockpitView.modelGloss(CockpitView.sanitizedAgentField(resolved)))"
        case .roster, nil: return nil
        }
    }

    /// The tooltip line naming how the model was chosen, or nil for `roster`
    /// and unknown sources.
    static func dispatchedHelpLine(for source: RunModelSource?) -> String? {
        switch source {
        case .overrideTyped: return "Model chosen: typed as an override at dispatch"
        case .overrideCo: return "Model chosen: a co passed --model at dispatch"
        case .overrideItem: return "Model chosen: set on the work item (who set it is claimed, not verified)"
        case .overrideUnattributed: return "Model chosen: an override at dispatch; who chose it was not recorded"
        case .failover: return "Model chosen: fail-over; nobody chose this model"
        case .roster, nil: return nil
        }
    }

    /// The mark for one session row, from that session's live runs joined to
    /// the register by `run_id`. Nil when no run draws a mark.
    ///
    /// A run absent from the register (private, ended, or the register was
    /// unreachable) has nothing to join and contributes nothing. When runs
    /// disagree the fail-over glyph wins, since it is the one nobody chose;
    /// the hover lists every marked run either way.
    static func resolve(runs: [SessionState.AgentRun],
                        register: [String: RunModelChoice]) -> RunModelMark? {
        var kinds: [RunModelMarkKind] = []
        var lines: [String] = []
        for run in runs {
            guard let id = run.runId, let choice = register[id],
                  let kind = kind(for: choice.source),
                  let line = sentence(agent: run.agent, choice: choice) else { continue }
            kinds.append(kind)
            lines.append(line)
        }
        guard !kinds.isEmpty else { return nil }
        return RunModelMark(kind: kinds.contains(.failover) ? .failover : .override,
                            help: lines.joined(separator: "\n"))
    }
}

/// The run register's `GET /runs`, read over the same ssh ControlMaster every
/// other verb rides.
///
/// **THE FIELDS DECK RELIES ON**, all read per run and all optional:
/// `runs[].run_id` (the join key to `agent_runs`), `runs[].model` and
/// `runs[].model_source`, plus `runs[].model_resolved` and `runs[].task` when
/// served. Every
/// other field the register serves is ignored.
enum RunRegister {
    /// A shell string, expanded on the mini so the socket path follows that
    /// host's own home. `-f` turns an HTTP error into a non-zero exit, and
    /// `-m 5` bounds a wedged socket; either way the caller reads a failure
    /// and draws no marks.
    static let remoteCommand =
        "curl -sS -f -m 5 --unix-socket \"$HOME/.local/run/run-register-api.sock\" http://x/runs"

    static func arguments(target: SSHTarget,
                          controlPath: String = defaultControlPath(),
                          home: String = NSHomeDirectory()) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            remoteCommand,
        ], home: home)
    }

    /// Decodes the envelope `{"generated_at": …, "runs": [ … ]}` into a
    /// table keyed by `run_id`. Nil when the body is not that envelope, which
    /// the caller treats as a failed read. An entry with no string `run_id`
    /// is skipped; a `model` or `model_source` that is null, missing or the
    /// wrong type costs only that field.
    static func decode(_ data: Data) -> [String: RunModelChoice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = root["runs"] as? [Any] else { return nil }
        var out: [String: RunModelChoice] = [:]
        for entry in runs {
            guard let dict = entry as? [String: Any], let id = dict["run_id"] as? String else { continue }
            out[id] = RunModelChoice(
                model: dict["model"] as? String,
                source: (dict["model_source"] as? String).flatMap(RunModelSource.init(wire:)),
                modelResolved: dict["model_resolved"] as? String,
                task: dict["task"] as? String)
        }
        return out
    }

    static func fetch(target: SSHTarget) throws -> [String: RunModelChoice] {
        let raw = try SessionAgent.run(try arguments(target: target), classifyMissingCommand: false,
                                       staleSocketRecovery: (target: target,
                                                             controlPath: defaultControlPath()))
        guard let table = decode(raw) else {
            throw SessionAgent.AgentError.failed("the run register answered something other than /runs")
        }
        return table
    }
}
