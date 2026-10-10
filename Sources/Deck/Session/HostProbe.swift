import Foundation

/// Reads a host's own idea of its name — `hostname -s` — for the
/// `user@machine` label. See
/// `deck/specs/multiple-sessions-per-project` §"Crews on different hosts":
/// "The machine part is read from the box itself... rather than taken from
/// a config label, so it says what the machine calls itself."
///
/// A PLAIN SHELL COMMAND, NOT A `session-agent` VERB. This is not part of
/// the `session-agent-api` contract — it never asks the mini for anything
/// session-shaped, just runs one word over the same ControlMaster the rail's
/// poll already holds open. Whether it should become a `session-agent` verb
/// instead is an open question for the platform side; see this phase's PR
/// body.
enum HostProbe {
    /// Same ControlMaster options as `SessionAgent`'s verbs, so this rides
    /// the connection the rail's `states`/`sessions` calls already opened
    /// rather than negotiating a second one.
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

    /// Runs the probe and returns the trimmed answer. Throws on the same
    /// transport failures `SessionAgent.run` does — an unreachable host, a
    /// non-zero exit — which the caller treats as "not landed yet" rather
    /// than a fatal error, the same degradation an unreachable host's
    /// `states`/`sessions` calls already get.
    static func probe(target: SSHTarget) throws -> String {
        let data = try SessionAgent.run(
            arguments(target: target), classifyMissingCommand: false)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionAgent.AgentError.failed("hostname -s returned nothing decodable")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Classifies a landed probe's raw `hostname -s` answer — PURE, so this
    /// is pinned by a test without an ssh round trip, the same discipline
    /// `HostTestOutcome.classify` follows for ssh's own stderr text. `name`
    /// is the far side's own answer, so it goes through the same charset
    /// gate and length cap as every other machine name `HostDisplay`
    /// renders — see its doc comment — rather than reaching a view unsanitized.
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
            } catch {
                return HostTestOutcome.classify(errorText: "\(error)")
            }
        }.value
    }
}
