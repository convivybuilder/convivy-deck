import Foundation

/// One Keel-shaped endpoint: an ssh target and the remote unix-socket path
/// its HTTP server listens on.
///
/// TWO ENDPOINTS, ONE VOCABULARY — `platform/contracts/deck-keel-wire`'s own
/// framing. The per-machine Individuator (process control) and the Library
/// (documents, moving to the Mac Studio around October 2026) are reached
/// this same way, each with its own `KeelEndpoint` value — nothing about
/// this type is specific to either.
///
/// **`run-register-api` IS NOT THE INDIVIDUATOR, and this type is where the
/// two are easiest to conflate** — an endpoint value pointing at
/// `~/.local/run/run-register-api.sock` is the only thing that answers today,
/// so it is tempting to describe it as the process-control endpoint. It is
/// not, and the contract states why: that socket is mode 0600 under one
/// operator's home on a per-user launchd job, so a second account is refused
/// at `connect()` before any protocol runs, and nothing in it identifies a
/// peer. Serving every account and telling accounts apart are the
/// Individuator's two defining requirements, so it is structurally incapable
/// of both. It is read-only telemetry behind a field allowlist, which is why
/// the READ half may be exercised against it while the sixteen mutating,
/// authorization-bearing verbs wait for an endpoint that does not exist yet.
/// The distinction already cost a correction in the decision record; do not
/// reintroduce it in a comment.
///
/// A NEW TYPE RATHER THAN A REDESIGN of anything `convivy-deck#143` landed —
/// `KeelEnvelope`/`KeelError`/`KeelErrorKind`/`KeelJSONValue`/
/// `KeelCallerKind` say nothing about WHERE a request goes, only how to read
/// what came back and who is asking; this is the piece the transport needed
/// that they deliberately left out.
struct KeelEndpoint: Equatable {
    let target: SSHTarget
    let remoteSocketPath: String
}
