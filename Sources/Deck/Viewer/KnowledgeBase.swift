import Foundation

/// Deck's whole view of the knowledge base: check a document out, return it.
///
/// ## Why this is one narrow type rather than calls scattered where they're needed
///
/// `platform/decisions/0020` settles how KB content changes: **a document is
/// checked out of the Library, edited, and returned to the Library, and direct
/// edits to a backing store are forbidden regardless of who makes them.** Deck
/// is one of the things that must not reach around that.
///
/// ## Deck performs the round trip only under evidence it may honestly offer
///
/// Checkout is live: `agentctl kb checkout` returns a document's bytes and the
/// sha to return them against, and writes nothing to disk.
///
/// The write verbs are live too, and it matters that they are. `agentctl kb
/// apply --base-sha <sha> --provenance <p>` accepts an edited document against
/// its content sha, refuses it as stale when `origin/main` has moved, and runs
/// the knowledge repo's validator before it commits. `agentctl kb propose`
/// routes the same write through a pull request. **What most of Deck lacks is
/// the authority to call either, and NOT a verb to call.** Do not read the gap
/// here as missing machinery; that reading rebuilds the design the operator rejected.
/// `--provenance person` is the one exception, and only once Deck can back it
/// with a Deck signature — see below.
///
/// 0020 makes the Reference Room's boundary the repository's write credential,
/// held only by the Library, and calls it "the hard one" because git hands out
/// extra write paths as a feature. `kb apply --help` documents six
/// provenances; only `in-session` and `person` write main directly, and
/// `person` needs evidence — a Cloudflare Access assertion, or a Deck
/// signature — that an attested agent session cannot honestly assert on a
/// person's behalf. An earlier version of this file opened pull requests
/// through `agentctl kb propose` regardless, citing 0020's discipline while
/// implementing the bypass it exists to close.
///
/// ## The return half now has a provenance: a Secure Enclave signature
///
/// `platform/contracts/library-protocol` §2.2 gives Deck that evidence: a
/// Touch-ID-gated Secure Enclave key signs an envelope of the write's
/// canonical path, base sha and content hash, `kb apply --provenance person`
/// verifies the signature and the signing certificate's chain to the
/// Library's root, and only then records the write as the certificate's
/// person. `submit(target:document:content:signingKey:certificatePEM:)` is
/// that call. It still is not Deck opening a pull request or pushing a
/// branch — the write lands through `kb apply`'s own verification, which is
/// the credential 0020 reserves to the Library, not a path around it.
///
/// A save with no certificate stored yet, or a cancelled Touch ID prompt,
/// sends nothing and stays a local draft (`saveLocally`) — the certificate
/// import this depends on is `issue_01M3CDHWFEQ4RCGMS9FT6Z88MC`, blocked on
/// the root-ca ceremony.
///
/// ## Deck does not reconcile, on purpose
///
/// A concurrent edit to the same document is the Library's problem, not Deck's.
/// When the return verb lands, Deck hands over the document it checked out and
/// the sha it holds; what happens to a document that moved underneath is
/// decided over there. Computing anchored hunks here would be Deck
/// implementing the Library's reconciliation in the wrong component.
enum KnowledgeBase {

    /// A document as checked out: its bytes, and the sha to return them against.
    ///
    /// The sha is carried from the moment of checkout so the return has a
    /// precondition to offer when one exists. Nothing consumes it yet; it is
    /// held rather than dropped because re-deriving it later would mean a
    /// second read, and a second read can disagree with the first.
    struct CheckedOutDocument: Equatable, Sendable {
        let id: String
        let content: String
        let contentSha: String
        /// The repository-relative path `kb checkout` resolved `id` to
        /// (`source_ref` in its JSON) — `projects/deck/specs/session-pane.md`
        /// for an id of `deck/specs/session-pane`, for instance. A signed
        /// save's envelope signs this, not `id`: `kb apply` resolves the same
        /// id through the same lookup and rebuilds the envelope from what it
        /// resolves to, so a signature over `id` would never verify.
        let sourceRef: String
        /// The host `checkout` ran against — carried so `release` can send its
        /// own ssh call to the same host without re-resolving it.
        let target: SSHTarget
    }

    enum KBError: Error, Equatable {
        case unexpectedResponse(String)
    }

    // MARK: - Checkout

    /// ssh argv for `agentctl kb checkout <id>`.
    ///
    /// A doc id is `[a-z0-9-]` in three segments, enforced by
    /// `DeckOpenRef.validateKBId`, so it carries no shell metacharacter. It is
    /// quoted anyway, for the reason every other path here is: a charset
    /// assumption is a weaker guarantee than quoting.
    static func checkoutArguments(
        target: SSHTarget,
        id: String,
        note: String = "opened in Deck's editor",
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            "agentctl", "kb", "checkout", SessionAgent.shellQuotePath(id),
            "--note", SessionAgent.shellQuotePath(note),
        ], home: home)
    }

    /// Checks a document out and returns its content with the sha to submit against.
    ///
    /// `kb checkout` writes nothing to disk — it reads the committed ref rather
    /// than the shared checkout, which trails main — so the bytes this returns
    /// are the bytes the sha guards. Holding them in Deck is the tool's
    /// intended use rather than a workaround.
    static func checkout(target: SSHTarget, id: String) throws -> CheckedOutDocument {
        let data = try SessionAgent.run(checkoutArguments(target: target, id: id))
        return try parseCheckoutResponse(data, id: id, target: target)
    }

    /// The shape a content sha must have: 64 lowercase hex characters, the
    /// same 64-lowercase-hex-character contract `SignedSaveEnvelope` signs
    /// over and `applyArguments` sends as `--base-sha`. `content_sha` reaches
    /// here as an untyped cast out of JSON with no format check of its own;
    /// this is that check. `applyArguments` also quotes `baseSha` for the
    /// same reason every other value crossing into the remote shell's argv
    /// is quoted, but a value that cannot even be a sha should never reach
    /// that argv at all — found by `deck-security-reviewer` on #286, since an
    /// upstream bug or a compromised Library response could otherwise hand a
    /// shell-metacharacter string to a write path meant to be
    /// cryptographically gated.
    private static let contentShaPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")

    static func isValidContentSha(_ sha: String) -> Bool {
        let range = NSRange(sha.startIndex..., in: sha)
        return contentShaPattern.firstMatch(in: sha, range: range) != nil
    }

    /// Parses `kb checkout`'s JSON response, separated from `checkout` so the
    /// parsing and validation are testable without a real ssh call.
    static func parseCheckoutResponse(
        _ data: Data, id: String, target: SSHTarget
    ) throws -> CheckedOutDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? String,
              let sha = root["content_sha"] as? String,
              let sourceRef = root["source_ref"] as? String else {
            throw KBError.unexpectedResponse(
                String(data: data, encoding: .utf8) ?? "(unreadable)")
        }
        guard isValidContentSha(sha) else {
            throw KBError.unexpectedResponse(
                "content_sha is not 64 lowercase hex characters: \(sha)")
        }
        return CheckedOutDocument(
            id: id, content: content, contentSha: sha, sourceRef: sourceRef, target: target)
    }

    // MARK: - Release

    /// ssh argv for `agentctl kb release <id>`.
    ///
    /// THE LEASE IS ADVISORY DEDUP, NOT A GATE. It says a document is being
    /// worked on; it does not reserve the right to change one, and Deck has no
    /// such right to reserve. A lease left behind costs the next writer noise
    /// rather than safety.
    ///
    /// Deck drops it when the editor closes, which is the only moment it can:
    /// there is no submit to drop it at, because there is nothing to submit to.
    /// An abandoned edit therefore does not leave one behind for its full four
    /// hours.
    static func releaseArguments(
        target: SSHTarget,
        id: String,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            "agentctl", "kb", "release", SessionAgent.shellQuotePath(id),
        ], home: home)
    }

    /// Drops the lease, ignoring failure.
    ///
    /// Nothing depends on this succeeding, and surfacing "could not release a
    /// lease" to someone who has just closed a window would be noise about a
    /// thing they cannot act on.
    static func release(target: SSHTarget, id: String) {
        _ = try? SessionAgent.run(releaseArguments(target: target, id: id),
                                  classifyMissingCommand: false)
    }

    // MARK: - Local draft — the fallback every save lands in first

    /// Saves an edited KB document to its working copy.
    ///
    /// ## Why a draft exists even now that `submit` can return a document
    ///
    /// `platform/decisions/0020` makes the Reference Room's boundary the
    /// repository's write credential: **only the Library holds it**, and the
    /// ADR calls this "the hard one" precisely because git hands out extra
    /// write paths as a feature. It names a CI token with `contents: write` as
    /// a vector to close. A GUI on a laptop that builds a branch, pushes it and
    /// opens a pull request with the operator's credential is the same vector wearing
    /// different clothes — which is exactly why `submit` below routes through
    /// `kb apply`'s own signature verification rather than doing either.
    ///
    /// An earlier version of this file opened a pull request anyway, via
    /// `agentctl kb propose`. It cited 0020's checkout-and-return discipline as
    /// justification and then implemented the thing 0020 exists to prevent —
    /// return meant "open the pull request myself" rather than "hand it to
    /// whoever holds the credential". Caught by the operator, not by review.
    ///
    /// This draft is what a save falls back to when `submit` cannot reach the
    /// knowledge base honestly: no certificate stored yet, a cancelled Touch ID
    /// prompt, or a refusal from `kb apply`. What must not happen is a reader
    /// believing their change reached the knowledge base when it did not,
    /// which is why this returns a URL the status line can name rather than a
    /// quiet success.
    /// A DRAFT WRITES BESIDE THE FETCHED COPY, NEVER OVER IT. Both this and
    /// `WorkingCopyStore.fetch(kbId:)` write into one directory, and while they
    /// shared a filename an edit replaced the copy the read-only viewer reads.
    /// Pressing Done then showed the reader their own draft as though it were
    /// the document — with no banner, because the surface that explains the
    /// difference is the one they just left. Deck exists partly for someone who
    /// does not work in a terminal, and that reader has no other way to tell
    /// what they wrote from what the knowledge base holds.
    static func saveLocally(document: CheckedOutDocument,
                            content: String) throws -> URL {
        let dir = try WorkingCopyStore.directory(forKBId: document.id)
        let fileURL = draftURL(forKBId: document.id, in: dir)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Where the draft of `kbId` sits inside its working-copy `directory`. The
    /// one naming rule, so a held save sent later derives the same path this
    /// write used rather than trusting a path carried on disk.
    static func draftURL(forKBId kbId: String, in directory: URL) -> URL {
        let name = kbId.split(separator: "/").last.map(String.init) ?? "document"
        return directory.appendingPathComponent("\(name)\(Self.draftSuffix)")
    }

    /// What a draft's filename ends in.
    ///
    /// Named rather than inlined so the viewer and any future reload path agree
    /// with the writer about which file is which, instead of two string
    /// literals in different types that have to be kept equal by hand.
    nonisolated static let draftSuffix = ".draft.md"

    /// What the pane tells a reader after a KB save.
    ///
    /// SAY WHERE IT DID NOT GO, NOT ONLY WHERE IT DID. "Saved" alone would be
    /// read as "saved to the knowledge base", which is the one thing that did
    /// not happen. A reader who believes an edit landed and closes the window
    /// has lost it as surely as if the write had failed.
    /// SAY WHERE IT DID NOT GO, AND PROMISE ONLY WHAT IS TRUE. An earlier
    /// version ended "your working copy is safe", which returning to the viewer
    /// made false — the fetched copy is refreshed there. The draft is what
    /// survives, so the draft is what this names.
    nonisolated static let notReturnedExplanation =
        "Saved on this Mac only, as a draft beside the document. This edit "
        + "cannot be checked back in yet — this Mac has no signing "
        + "certificate to sign it with, or the Touch ID prompt was "
        + "cancelled — so nothing on the knowledge base has changed and "
        + "this edit is queued nowhere."
}
