import Foundation

struct SSHTarget: Hashable {
    var user: String
    var host: String
}

enum SSHTargetError: Error, Equatable {
    case invalidSessionName(String)
    case invalidWorkingDirectory(String)
    case invalidHostUser(String)
    case invalidHostAddress(String)
    case invalidHostName(String)
}

/// tmux session names come from a text field today and a fleetd-driven rail
/// later; either way they end up on the far side of `ssh`, which joins its
/// trailing arguments with spaces and hands the result to the remote shell.
/// Restricting the charset up front removes remote shell injection as a
/// possibility rather than relying on quoting it correctly.
private let allowedSessionNameCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
)

func validateTmuxSessionName(_ name: String) throws -> String {
    guard !name.isEmpty, name.count <= 64,
          name.unicodeScalars.allSatisfy(allowedSessionNameCharacters.contains) else {
        throw SSHTargetError.invalidSessionName(name)
    }
    return name
}

/// A working directory comes from the same config file a user hand-edits, and
/// lands in the same remote-shell command as the session name — so it needs its
/// own gate for its own reason. The session-name charset is too narrow to reuse
/// (a path needs `/`) and too permissive in one place: a leading `-` would be
/// read by tmux as a flag rather than a path.
///
/// Spaces are rejected rather than quoted. ssh joins its trailing arguments and
/// hands the string to the remote shell, so a quoted path would have to survive
/// two levels of splitting correctly; refusing the case is honest, and no fleet
/// workdir has a space in it. Revisit by sending the command over stdin instead
/// of argv, which removes the joining entirely.
private let allowedWorkingDirectoryCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/~"
)

func validateWorkingDirectory(_ path: String) throws -> String {
    // Absolute or home-relative only. A bare relative path would resolve
    // against whatever directory the remote login happens to start in, which
    // makes the rail row's behaviour depend on the remote shell's profile.
    guard !path.isEmpty, path.count <= 1024,
          path.hasPrefix("/") || path.hasPrefix("~/"),
          !path.contains(".."),
          path.unicodeScalars.allSatisfy(allowedWorkingDirectoryCharacters.contains) else {
        throw SSHTargetError.invalidWorkingDirectory(path)
    }
    return path
}

/// `SSHTarget.user` comes from a hand-edited `theme.json`'s `hosts` table and
/// lands directly in the ssh destination token, `"\(user)@\(host)"` — no
/// shell is involved locally, but ssh parses that token against its own
/// option grammar. A LEADING `-` IS THE CASE THAT MATTERS: a user (or
/// address) beginning with `-` makes the whole token look like another ssh
/// flag (e.g. `-oProxyCommand=...`) rather than a destination, which runs
/// client-side with Deck's own privileges — the same shape as the
/// `ssh://-oProxyCommand=...` injection class. Mirrors
/// `validateTmuxSessionName`'s reasoning for the same reason: this is a
/// config-sourced string reaching argv.
private let allowedHostUserCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
)

func validateHostUser(_ user: String) throws -> String {
    guard !user.isEmpty, user.count <= 64, !user.hasPrefix("-"),
          user.unicodeScalars.allSatisfy(allowedHostUserCharacters.contains) else {
        throw SSHTargetError.invalidHostUser(user)
    }
    return user
}

/// `SSHTarget.host` gets the same gate as `user`, for the same reason and at
/// the same leading-`-` case. The charset adds `:` for an IPv6 literal, which
/// a hostname or IPv4 address never needs but an address never rejects on
/// its own account either.
private let allowedHostAddressCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:"
)

func validateHostAddress(_ address: String) throws -> String {
    guard !address.isEmpty, address.count <= 253, !address.hasPrefix("-"),
          address.unicodeScalars.allSatisfy(allowedHostAddressCharacters.contains) else {
        throw SSHTargetError.invalidHostAddress(address)
    }
    return address
}

/// `HostEntry.name`/`Crew.host`/`LaunchableSession.host` — the config KEY a
/// host is referenced by, never sent to ssh directly. `HostResolution` only
/// ever uses it as an equality key into `hosts`, whose own `user`/`address`
/// are what actually reach argv — so this gate isn't closing an injection.
/// It closes a narrower thing: `SessionRef.stringForm` joins `host` and a
/// tmux session name with `|`, on the assumption that a host name can never
/// contain one. Reusing `validateTmuxSessionName`'s charset (letters,
/// digits, `._-`) makes that assumption true rather than merely stated —
/// the charset contains no `|` by construction.
func validateHostName(_ name: String) throws -> String {
    guard !name.isEmpty, name.count <= 64,
          name.unicodeScalars.allSatisfy(allowedSessionNameCharacters.contains) else {
        throw SSHTargetError.invalidHostName(name)
    }
    return name
}

/// The prefix every scratch-shell tmux session carries.
///
/// A PREFIX RATHER THAN A SUFFIX, so `tmux ls` groups them and a reaper can
/// match them without knowing the fleet's session names. It also cannot collide
/// with a fleet session: a rail row named `deck-shell-vivy` would have to be
/// configured deliberately, and the worst case is sharing a shell rather than
/// touching an agent.
let scratchShellPrefix = "deck-shell-"

/// The tmux session Builder's macOS install starts at login
/// (`com.convivy.tmux-keeper`), so the tmux server is up from boot and Claude
/// sessions started inside it over SSH can read the login Keychain. It holds an
/// empty shell nobody works in, so the rail leaves it out of OTHER SESSIONS.
///
/// The name is fixed by Builder's install job (Shipwright's
/// `issue_01M3JE2BTB8RG70YPWQXVS6TN4`); change it only together with that job,
/// or the rail starts drawing the session again.
let keeperSessionName = "keeper"

/// The tmux session name for a fleet session's scratch shell.
///
/// The fleet name is TRUNCATED rather than rejected when the pair would exceed
/// the 64-character cap `validateTmuxSessionName` enforces. Refusing would mean
/// a long rail row silently loses its shell — a worse outcome than a truncation
/// collision, which is guarded elsewhere rather than here: two names that agree
/// on the first `64 - scratchShellPrefix.count` characters would produce the
/// same scratch-shell session. TWO guards check this function's output before
/// a name is accepted, one per path a name can arrive by:
///
/// - `SiblingSessionName.derive`, against every existing session, on the spawn
///   path;
/// - `ThemeConfiguration`'s `droppingScratchShellCollisions`, across every rail
///   row, catalog row, and child in one pass, on the config-parse path — a name
///   typed straight into `theme.json` reaches the rail only through it.
///
/// COUNT THEM WHEN YOU ADD ONE. Earlier versions of this comment said "two
/// guards" and then "three" while omitting a guard that existed — so a reader
/// adding a new entry point had a completeness claim that was not true. Found
/// by `deck-security-reviewer` on #132. Two guards have since gone with the
/// surfaces that fed them: the "+ New" crew sheet's id derivation, and
/// `SessionRoster.add`, which checked a name typed into Settings › Sessions'
/// add sheet. Neither surviving way to get a crew id reaches a free-text
/// derivation: `StewardCrew.create` writes a fixed `"steward"`, and
/// `SessionPromotion.derive` takes the id from a tmux session that is already
/// running, so the name it adopts was minted by tmux rather than derived here.
/// A NEW path that takes an id from free text needs its own guard; do not read
/// this as "ids are safe now".
func scratchShellSessionName(for session: String) -> String {
    let budget = 64 - scratchShellPrefix.count
    return scratchShellPrefix + String(session.prefix(budget))
}

/// Whether `name`'s scratch-shell session would collide with any name already
/// in `existingNames` — an exact match, or one that merely agrees with `name`
/// on the prefix `scratchShellSessionName` truncates to.
///
/// The single-candidate-against-a-set shape `SiblingSessionName.derive` uses.
/// `ThemeConfiguration.droppingScratchShellCollisions`
/// checks the same thing across many names at once and keeps its own
/// accumulating set for that rather than calling this per name.
func scratchShellCollides(_ name: String, with existingNames: Set<String>) -> Bool {
    let scratchName = scratchShellSessionName(for: name)
    return existingNames.contains { scratchShellSessionName(for: $0) == scratchName }
}

/// One ControlMaster socket carries every pane plus the eventual fleetd
/// forward (fork 3): `%C` is ssh's own hash of (host, port, user), which
/// keeps the control socket under the UNIX path-length limit regardless of
/// session name length.
func defaultControlPath(homeDirectory: String = NSHomeDirectory()) -> String {
    "\(homeDirectory)/.ssh/deck-cm-%C"
}

/// Builds the argv for attaching one terminal pane to a tmux session on the
/// mini. No shell is involved on the local side — `Process` takes this array
/// as literal argv, so only the remote hop (ssh's own arg-joining) needs the
/// session-name validation above, plus the target's own user/address, since a
/// config-sourced host reaches this destination token the same way a
/// config-sourced session name or working directory does.
func sshArguments(
    target: SSHTarget,
    tmuxSession: String,
    workingDirectory: String? = nil,
    controlPath: String = defaultControlPath(),
    home: String = NSHomeDirectory()
) throws -> [String] {
    let user = try validateHostUser(target.user)
    let host = try validateHostAddress(target.host)
    let session = try validateTmuxSessionName(tmuxSession)
    let directory = try workingDirectory.map(validateWorkingDirectory)
    // `new-session -A` attaches when the session exists and creates it when it
    // does not, which is what makes a rail row work on a session that is merely
    // stopped rather than missing. `-D` detaches any other client, matching the
    // `tmux attach -d` in the operator's ssh aliases: two clients on one session resize
    // each other's panes to the smaller window.
    //
    // `-c` is honoured only on creation, so passing it costs nothing when
    // attaching to a session that already exists.
    var tmuxCommand = ["tmux", "new-session", "-A", "-D", "-s", session]
    if let directory { tmuxCommand += ["-c", directory] }
    return withDeckIdentity([
        // Given a remote command, ssh allocates no remote PTY unless asked —
        // regardless of the local PTY SwiftTerm hands it. Without this tmux
        // attaches to nothing and exits "open terminal failed: not a terminal".
        "-t",
        "-o", "ControlMaster=auto",
        "-o", "ControlPersist=10m",
        "-o", "ControlPath=\(controlPath)",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "\(user)@\(host)",
    ] + tmuxCommand, home: home)
}

/// argv for `ssh -O check`, which asks an existing control socket's master
/// whether it is still running — see `SSHControlSocket`. No verb, no
/// session: this never reaches the remote side at all when a master answers,
/// which is what makes it usable as a probe rather than a connection attempt
/// of its own.
func sshControlSocketCheckArguments(
    target: SSHTarget, controlPath: String, home: String = NSHomeDirectory()
) throws -> [String] {
    let user = try validateHostUser(target.user)
    let host = try validateHostAddress(target.host)
    return withDeckIdentity(
        ["-O", "check", "-o", "ControlPath=\(controlPath)", "\(user)@\(host)"], home: home)
}

/// argv for `ssh -G`, which prints ssh's fully resolved configuration for
/// `target` with every token in `controlPath` — `%C` above all — expanded to
/// the literal value ssh would actually use. A purely local operation, no
/// network round trip and no existing control socket involved, so it cannot
/// hang the way a real connection attempt can; see `SSHControlSocket.clear`.
func sshResolvedConfigArguments(
    target: SSHTarget, controlPath: String, home: String = NSHomeDirectory()
) throws -> [String] {
    let user = try validateHostUser(target.user)
    let host = try validateHostAddress(target.host)
    return withDeckIdentity(
        ["-G", "-o", "ControlPath=\(controlPath)", "\(user)@\(host)"], home: home)
}

/// argv for `ssh -O cancel`, which asks whichever process holds the shared
/// control socket at `controlPath` to drop one `-L` forward's mapping —
/// `KeelForward.stop()`'s own mechanism for closing its forward without
/// risking the shared ControlMaster. See `KeelForward.stop()`'s doc for why
/// a bare `process.terminate()` on the forward's own `ssh -N` process is
/// unsafe here: that process may itself be the master. `remoteSocketPath`
/// gets the same validation `keelForwardArguments` applies, since the same
/// `-L` field reaches this argv the same way.
func sshCancelForwardArguments(
    target: SSHTarget, remoteSocketPath: String, localPort: UInt16, controlPath: String,
    home: String = NSHomeDirectory()
) throws -> [String] {
    let user = try validateHostUser(target.user)
    let host = try validateHostAddress(target.host)
    let path = try validateWorkingDirectory(remoteSocketPath)
    return withDeckIdentity([
        "-O", "cancel",
        "-L", "127.0.0.1:\(localPort):\(path)",
        "-o", "ControlPath=\(controlPath)",
        "\(user)@\(host)",
    ], home: home)
}


