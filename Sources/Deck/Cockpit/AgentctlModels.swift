import Foundation

/// The list of models a dispatch will accept — `agentctl models --json` on
/// the host, per `platform/contracts/agentctl-models`. The Item pane's model
/// control (`ItemDetailPane.modelControl`) is this contract's only Deck
/// consumer: it offers a picker built from this list rather than free text,
/// because free text let the operator type `claude-opus` on 2026-09-28 and have the
/// Bosun refuse it at dispatch — the entry line this contract exists to
/// close.
enum AgentctlModels {
    /// One selectable model, in the order the host gave it.
    struct ModelEntry: Equatable, Sendable {
        /// The short name `MODEL_ALIASES` maps to this model, or `nil` when
        /// the model has none.
        let alias: String?
        /// The resolved model id — what a dispatch compares and records, and
        /// what a consumer stores (the contract's "What a consumer stores").
        let model: String
        let provider: String?
    }

    enum Outcome: Equatable, Sendable {
        case models([ModelEntry])
        /// The command's non-zero exit, unparseable stdout, or an unknown
        /// `schema_version` — the contract's three "list unavailable" cases.
        /// A picker built on this shows that and keeps Set disabled; it never
        /// falls back to accepting free text as though it were valid.
        case unavailable
    }

    /// The only `schema_version` this reads. The contract raises it when a
    /// field is removed, renamed, or changes type or meaning — a version this
    /// does not know is refused, per the contract, rather than parsed on a
    /// guess about what changed.
    static let supportedSchemaVersion = 1

    /// Validates `user` and `host` the way every other ssh argv builder does
    /// (`sshArguments`, `sshControlSocketCheckArguments`), so a value
    /// beginning with `-` can never reach ssh as an option.
    static func arguments(
        target: SSHTarget,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            "agentctl", "models", "--json",
        ], home: home)
    }

    /// A PURE FUNCTION OF THE BYTES, so every shape — a good list, a bad
    /// schema version, a malformed entry — can be pinned by a test without an
    /// ssh round trip, the same split `SessionAgent.decodeDelta` uses.
    ///
    /// THE ORDER IS PRESERVED EXACTLY AS GIVEN. The contract fixes it
    /// (aliased models first in `MODEL_ALIASES` order, then unaliased tier
    /// ids), so this never sorts — a picker built from it draws the array in
    /// the order it decodes.
    ///
    /// ONE MALFORMED ENTRY INVALIDATES THE WHOLE LIST, the same discipline
    /// `decodeDelta` gives a malformed row: a partial list a Set could
    /// dispatch against is a worse failure than an unavailable control.
    static func decode(_ data: Data) -> Outcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any],
              let schemaVersion = root["schema_version"] as? Int,
              schemaVersion == supportedSchemaVersion,
              let rawModels = root["models"] as? [Any] else {
            return .unavailable
        }
        var entries: [ModelEntry] = []
        entries.reserveCapacity(rawModels.count)
        for item in rawModels {
            guard let dict = item as? [String: Any],
                  let model = dict["model"] as? String, !model.isEmpty else {
                return .unavailable
            }
            entries.append(ModelEntry(
                alias: dict["alias"] as? String,
                model: model,
                provider: dict["provider"] as? String))
        }
        return .models(entries)
    }

    /// Runs `agentctl models --json` over the same ssh transport
    /// `SessionAgent`'s other host-wide verbs use (`sessions`, `crews`), and
    /// decodes it.
    ///
    /// EVERY FAILURE READS AS `.unavailable` — an unreachable host, a wedged
    /// ControlMaster, the command's own non-zero exit, malformed stdout. The
    /// contract draws no distinction a picker could act on differently: none
    /// of them is a list Set may dispatch against, so none gets a separate
    /// error path or a free-text fallback.
    static func fetch(target: SSHTarget) -> Outcome {
        guard let args = try? arguments(target: target),
              let data = try? SessionAgent.run(
                  args, classifyMissingCommand: false, throwOnNonZeroExit: false)
        else {
            return .unavailable
        }
        return decode(data)
    }
}

extension AgentctlModels.ModelEntry {
    /// The label a row draws: the alias beside the resolved model it names,
    /// or the model alone for an entry the host reports no alias for.
    var label: String {
        guard let alias, !alias.isEmpty else { return model }
        return "\(alias) (\(model))"
    }
}
