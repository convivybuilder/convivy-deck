import Foundation

/// Reads a host's own idea of its name — the `user@machine` label's machine
/// half. See `deck/specs/multiple-sessions-per-project` §"Crews on different
/// hosts": "The machine part is read from the box itself... rather than
/// taken from a config label, so it says what the machine calls itself."
///
/// ASKS THE INDIVIDUATOR'S `host-name` VERB FIRST (E5·2,
/// `platform/contracts/deck-keel-wire`) AND FALLS BACK TO `hostname -s` OVER
/// SSH ONLY WHEN THE WIRE ITSELF SAYS THERE IS NOTHING TO ASK. A fresh Linux
/// server and an older install both have no Individuator keel.sock yet, so
/// the ssh path stays as what those hosts land on; it never becomes the
/// first thing tried again.
enum HostProbe {
    /// The Individuator's wire socket on every host CQ·688 deployed it to —
    /// one named constant rather than a literal repeated at each call site.
    static let individuatorSocketPath = "/var/db/individuator-daemon/keel.sock"

    /// `host-name`'s own result shape, `{"host_name": "<string>"}`. A
    /// missing or non-string `host_name` simply fails to decode here, which
    /// `KeelClient.call` already turns into `KeelError.transport` — "a body
    /// that arrives but does not decode is transport, not a successful
    /// envelope" (`platform/contracts/deck-keel-wire`) — so that case needs
    /// no special handling in this file at all.
    struct HostNameResult: Decodable, Equatable {
        let hostName: String

        private enum CodingKeys: String, CodingKey {
            case hostName = "host_name"
        }
    }

    /// Same ControlMaster options as `SessionAgent`'s verbs, so this rides
    /// the connection the rail's `states`/`sessions` calls already opened
    /// rather than negotiating a second one. Used only by the ssh fallback
    /// now; `KeelForward` shares the same `defaultControlPath()` for the
    /// Keel path, for the same reason.
    ///
    /// `ConnectTimeout` IS SET HERE AND NOWHERE ELSE IN THIS CODEBASE. Every
    /// other verb already has a live session or a config-listed host
    /// backing it; this one runs against every declared host on every tick
    /// until it lands, including one that never answers, so it is the one
    /// call that needed a bound rather than the TCP default. Scoped to the
    /// probe on purpose — see `RailStateModel.refresh`'s finding, which
    /// asked for this fix here and explicitly not a change to the other
    /// verbs' timeout behaviour.
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
            "-o", "ConnectTimeout=5",
            "\(user)@\(host)",
            "hostname", "-s",
        ], home: home)
    }

    /// Asks the Individuator over a `KeelForward`, opened and torn down
    /// again within this one call.
    ///
    /// NOT HELD OPEN ACROSS TICKS. `RailStateModel.probedMachineNames`'s own
    /// doc already runs this probe AT MOST ONCE PER HOST PER APP RUN — a
    /// landed name is cached forever, a failed one backs off — so there is
    /// no second call this forward would ever be reused for. Holding it open
    /// would just be a live `ssh -N` process nothing calls through again,
    /// for the lifetime of the app. `KeelForward.stop()` cancels only this
    /// forward's own `-L` mapping (never the shared ControlMaster itself —
    /// see its own doc), so this is safe to do every time without
    /// disturbing a tmux pane or another `KeelForward` sharing the same
    /// master.
    static func fetchHostNameOverKeel(target: SSHTarget) throws -> KeelEnvelope<HostNameResult> {
        let forward: KeelForward
        do {
            forward = try KeelForward.start(target: target, remoteSocketPath: individuatorSocketPath)
        } catch {
            // `KeelForward.start`'s own failures (no free port, ssh never
            // launched, the forward never came up) are exactly what the wire
            // contract calls a transport failure: no envelope ever had a
            // chance to arrive.
            throw KeelError.transport("could not open the Individuator forward: \(error)")
        }
        defer { forward.stop() }
        // No token: CQ·688's own item ("The Individuator serves the wire
        // socket...") states none is required for anything it serves today,
        // and Deck has no credential issuer yet (`KeelCallerKind`'s own
        // doc) to attach one from. `.operatorSession` is the caller kind
        // because this runs as Deck's own ssh identity, not a dispatched
        // agent's.
        return try KeelClient.call(
            connection: .forwardedPort(forward.localPort),
            method: "POST", path: "/host-name",
            caller: .operatorSession(KeelToken("")))
    }

    /// The pre-E5·2 path, kept as the fallback: runs the probe over ssh and
    /// returns the trimmed answer. Throws on the same transport failures
    /// `SessionAgent.run` does — an unreachable host, a non-zero exit —
    /// which the caller treats as "not landed yet" rather than a fatal
    /// error, the same degradation an unreachable host's `states`/`sessions`
    /// calls already get.
    static func fetchHostNameOverSSH(target: SSHTarget) throws -> String {
        let data = try SessionAgent.run(
            arguments(target: target), classifyMissingCommand: false)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionAgent.AgentError.failed("hostname -s returned nothing decodable")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What `probe` does next, once asking the Individuator has answered or
    /// failed.
    enum KeelProbeOutcome: Equatable {
        case hostName(String)
        case fallBackToSSH
        case failed(KeelError)
    }

    /// PURE classification of a decoded `host-name` envelope — no socket, no
    /// process, the same discipline `HostTestOutcome.classify` follows for
    /// ssh's own stderr text.
    ///
    /// `no_such_method` IS THE ONE SERVER-TOLD KIND THAT FALLS BACK, AND
    /// NOTHING ELSE DOES. It is the Individuator saying this verb does not
    /// exist on its build. A host with no keel.sock at all never answers an
    /// envelope; the forwarded connection fails, and that reaches the
    /// fallback through `classify(fetchError:)` as `.transport`.
    /// `unauthenticated`, `forbidden`, `unavailable`,
    /// `refused`, and an unrecognised kind all mean the endpoint exists and
    /// either declined or could not serve the call right now; retrying the
    /// exact same question over a second transport (ssh) cannot change any
    /// of those answers and would only hide that the Individuator refused.
    /// Branches on `kind` alone, never on `message` — the wire contract's
    /// own rule.
    static func classify(envelope: KeelEnvelope<HostNameResult>) -> KeelProbeOutcome {
        switch envelope {
        case .ok(let result):
            return .hostName(result.hostName)
        case .error(let kind, let message, let detail):
            guard kind == .noSuchMethod else {
                return .failed(.server(kind: kind, message: message, detail: detail))
            }
            return .fallBackToSSH
        }
    }

    /// The same classification for a thrown transport failure. In
    /// production `fetchHostNameOverKeel` only ever throws `.transport` —
    /// `KeelClient.call` never constructs `.server` itself (see its own
    /// doc) — so the `.server` branch below is unreached today and kept
    /// only so this switch stays exhaustive rather than silently dropping a
    /// case if that ever changes.
    static func classify(fetchError: KeelError) -> KeelProbeOutcome {
        switch fetchError {
        case .transport:
            return .fallBackToSSH
        case .server(let kind, let message, let detail):
            return .failed(.server(kind: kind, message: message, detail: detail))
        }
    }

    /// Reads a host's short name: asks the Individuator's `host-name` verb
    /// first, and falls back to `hostname -s` over ssh only when
    /// `classify(envelope:)`/`classify(fetchError:)` say so. See their own
    /// docs for exactly which kinds fall back and which surface as this call
    /// failing.
    ///
    /// `fetchKeelHostName`/`fetchHostNameFallback` ARE SEAMS, NOT
    /// PRODUCTION CONFIGURATION — their defaults are the two functions above
    /// them in this file; a test substitutes a fake for either without a
    /// real socket or a real ssh process, the same seam discipline
    /// `RailStateModel`'s `fetchStates`/`fetchProbe` follow at the model
    /// layer.
    static func probe(
        target: SSHTarget,
        fetchKeelHostName: (SSHTarget) throws -> KeelEnvelope<HostNameResult> = fetchHostNameOverKeel,
        fetchHostNameFallback: (SSHTarget) throws -> String = fetchHostNameOverSSH
    ) throws -> String {
        let outcome: KeelProbeOutcome
        do {
            outcome = classify(envelope: try fetchKeelHostName(target))
        } catch let error as KeelError {
            outcome = classify(fetchError: error)
        }
        switch outcome {
        case .hostName(let name):
            return name
        case .fallBackToSSH:
            return try fetchHostNameFallback(target)
        case .failed(let error):
            throw error
        }
    }

    /// Classifies a landed probe's raw answer — PURE, so this is pinned by a
    /// test without a round trip, the same discipline `HostTestOutcome
    /// .classify` follows for ssh's own stderr text. `name` is the far
    /// side's own answer, so it goes through the same charset gate and
    /// length cap as every other machine name `HostDisplay` renders — see
    /// its doc comment — rather than reaching a view unsanitized.
    static func outcome(forProbedName name: String) -> HostTestOutcome {
        guard !name.isEmpty else {
            return .refused("hostname -s returned nothing")
        }
        return .reachable(machineName: HostDisplay.machineLabel(
            probed: name, configName: nil, address: nil))
    }

    /// The Hosts tab's Test button — runs the same probe `RailStateModel`
    /// polls with, off the main actor, and classifies the result into the
    /// three outcomes the button reports plainly. See
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts" and `HostTestOutcome`.
    static func test(target: SSHTarget) async -> HostTestOutcome {
        await Task.detached {
            do {
                let name = try probe(target: target)
                return outcome(forProbedName: name)
            } catch let SessionAgent.AgentError.failed(text) {
                return HostTestOutcome.classify(errorText: text)
            } catch let KeelError.server(_, message, _) {
                // `message` is exactly the field the wire contract hands a
                // caller for a person to read — not branched on, only
                // displayed.
                return .refused(message)
            } catch let KeelError.transport(message) {
                return .unreachable(message)
            } catch {
                return HostTestOutcome.classify(errorText: "\(error)")
            }
        }.value
    }
}
