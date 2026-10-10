import Foundation

/// The client half of `platform/contracts/deck-keel-wire`'s transport: given
/// a connection (a direct unix socket, or an already-started
/// `KeelForward`'s local port) and a caller's token, performs one HTTP
/// request and decodes the response as a `KeelEnvelope`.
///
/// NOTHING HERE OPENS A CONNECTION FOR A VERB DECK ACTUALLY CALLS YET — no
/// endpoint serves any of the sixteen mutating `session-agent` verbs or
/// `host-name`, and this file calls none of them. This is the SPEAKER:
/// built once against the vocabulary `convivy-deck#143` landed
/// (`KeelEnvelope`/`KeelError`/`KeelErrorKind`/`KeelJSONValue`/
/// `KeelCallerKind`), and live-tested against the one thing that does
/// answer today — the read-only `run-register-api.sock` (see
/// `KeelClientLiveTests` for what "live" means here and what stays
/// fixture-only).
enum KeelClient {
    /// Runs one Keel call and decodes its envelope, or throws `KeelError`.
    ///
    /// TRANSPORT VS SERVER, EXACTLY THE CONTRACT'S OWN SPLIT
    /// (`platform/contracts/deck-keel-wire`, "`transport` cannot arrive in
    /// an envelope"). Anything that keeps a JSON body from arriving at
    /// all — no socket, connection refused, a connect or an I/O timeout, a
    /// body that does not decode as `{"ok": ..., ...}` — raises
    /// `KeelError.transport` HERE, at the point that actually observed the
    /// failure. Only a body that DOES decode reaches `KeelEnvelope`'s own
    /// `Decodable` conformance, whose `.error` case is what `.get()` turns
    /// into `KeelError.server` — this function never constructs `.server`
    /// itself, and never inspects `response.status` to decide which case to
    /// raise (see the second `do` block below for why).
    static func call<Result: Decodable>(
        connection: KeelConnection,
        method: String,
        path: String,
        caller: KeelCallerKind,
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) throws -> KeelEnvelope<Result> {
        let response: KeelHTTPExchange.Response
        do {
            let fd = try KeelSocket.connect(connection, timeout: timeout)
            response = try KeelHTTPExchange.exchange(
                fd: fd, method: method, host: "localhost", path: path,
                headers: ["Authorization": "Bearer \(caller.token.value)"],
                body: body, timeout: timeout)
        } catch let error as KeelSocketError {
            throw KeelError.transport(error.description)
        }
        // A BODY THAT ARRIVES BUT DOES NOT DECODE IS `transport`, NOT AN
        // UNRECOGNISED `kind` — the wire contract's own words, and the
        // whole reason this `do` block exists as a second, separate step
        // from the one above. Whatever HTTP status came back (200 with no
        // `ok` field at all — `run-register-api`'s real `/runs` shape today —
        // a 404 refusal in a shape this envelope was never meant to carry,
        // a proxy's HTML error page), the only question here is whether the
        // bytes decode as `{"ok": ..., ...}`. `response.status` is
        // deliberately never read: nothing is decided by HTTP status any
        // more than the contract says anything is decided by prose or exit
        // code. `KeelErrorKind.unrecognized(String)` is a DIFFERENT
        // failure at a DIFFERENT layer — a WELL-FORMED envelope carrying a
        // `kind` this build has not heard of — and this line is never
        // reached for that case, since a well-formed envelope decodes
        // successfully here regardless of which `kind` string it names.
        do {
            return try JSONDecoder().decode(KeelEnvelope<Result>.self, from: response.body)
        } catch {
            throw KeelError.transport(
                "HTTP \(response.status) did not carry a Keel envelope: \(error)")
        }
    }
}
