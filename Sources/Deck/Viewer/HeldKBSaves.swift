import Foundation

extension Notification.Name {
    /// Posted after a held save is sent or refused, so an open editor can show
    /// the document's new state.
    static let heldKBSavesDidChange = Notification.Name("deck.heldKBSavesDidChange")
}

/// A knowledge-base save Deck kept on this Mac because the signing certificate
/// was outside its validity window. It goes out when a renewed certificate is
/// imported, or when the person retries it in Settings › Signing.
///
/// The record holds the document id, the host, the `content_sha` the save was
/// edited against, the SHA-256 of the draft's bytes, and the draft's path. The
/// bytes are read from the draft when the save is sent, so the draft stays the
/// one copy of the edit and the record never holds document content. The record
/// lives in Deck's Application Support, never in the knowledge base or a repository.
struct HeldKBSave: Codable, Equatable, Identifiable {
    let documentId: String
    /// The repository-relative path the document checked out as. The signed
    /// envelope covers it (`CheckedOutDocument.sourceRef`), so a send needs it.
    let sourceRef: String
    /// The `content_sha` the save was edited against. `kb apply` refuses the send
    /// when the document has moved on since.
    let contentSha: String
    /// The SHA-256 of the draft's bytes when the save was held. The send signs
    /// whatever the draft holds, so it goes out only while the draft still hashes
    /// to this value.
    let draftSha256: String
    let user: String
    let host: String
    /// Absolute path of the `.draft.md` that `KnowledgeBase.saveLocally` wrote, at
    /// hold time. A send derives the path to read from the document id instead and
    /// only checks this field against it, so a record whose `draftPath` was edited
    /// to name another file is refused rather than followed.
    let draftPath: String
    let heldAt: Date
    /// Why the last attempt to send this save did not go out. Nil before any attempt.
    var reason: String?

    /// One held save per document and host. A later hold of the same document
    /// replaces the earlier record, because `saveLocally` writes the same draft file.
    var id: String { "\(user)@\(host):\(documentId)" }
    var target: SSHTarget { SSHTarget(user: user, host: host) }

    init(document: KnowledgeBase.CheckedOutDocument, draftSha256: String, draftPath: String, heldAt: Date) {
        documentId = document.id
        sourceRef = document.sourceRef
        contentSha = document.contentSha
        self.draftSha256 = draftSha256
        user = document.target.user
        host = document.target.host
        self.draftPath = draftPath
        self.heldAt = heldAt
        reason = nil
    }

    /// Whether `other` is this same hold: the same document and host, over the
    /// same draft bytes. A hold recorded later for the same document has new bytes
    /// and so is not this one.
    func isSameHold(as other: HeldKBSave) -> Bool {
        id == other.id && draftSha256 == other.draftSha256
    }
}

enum HeldKBSaveError: Error, Equatable, LocalizedError {
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .storage(let why): return "The held saves could not be read or written: \(why)"
        }
    }
}

/// The held saves, kept in `Deck/held-kb-saves.json` beside the signing key and
/// its certificate. A lock serializes each read-modify-write, because the editor
/// can record a hold while Settings records a send.
final class HeldKBSaveStore: @unchecked Sendable {
    static let shared = HeldKBSaveStore(fileURL: defaultFileURL())

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deck/held-kb-saves.json")
    }

    /// Every held save, in the order they were recorded. A file that is present
    /// but does not parse throws, so Settings shows the fault rather than
    /// reading as "nothing held".
    func all() throws -> [HeldKBSave] {
        lock.lock()
        defer { lock.unlock() }
        return try read()
    }

    /// Records `save`, replacing any held save with the same id in place.
    func record(_ save: HeldKBSave) throws {
        lock.lock()
        defer { lock.unlock() }
        var saves = try read()
        if let index = saves.firstIndex(where: { $0.id == save.id }) {
            saves[index] = save
        } else {
            saves.append(save)
        }
        try write(saves)
    }

    /// Drops the record that is `save`'s hold, when one is still stored. A hold
    /// recorded since `save` was read has other draft bytes and stays.
    func remove(_ save: HeldKBSave) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(try read().filter { !$0.isSameHold(as: save) })
    }

    /// Drops every hold on `documentId` at `target`, whatever its draft bytes. A
    /// direct save that reached the knowledge base has sent newer content for the
    /// document, so an older hold would only be refused later as changed since held.
    /// Writes nothing when no hold matches.
    func removeHolds(documentId: String, target: SSHTarget) throws {
        lock.lock()
        defer { lock.unlock() }
        let saves = try read()
        let kept = saves.filter { $0.documentId != documentId || $0.target != target }
        guard kept.count != saves.count else { return }
        try write(kept)
    }

    /// Sets the reason on the record that is `save`'s hold. A hold recorded since
    /// `save` was read is left with its own reason.
    func setReason(_ reason: String, for save: HeldKBSave) throws {
        lock.lock()
        defer { lock.unlock() }
        var saves = try read()
        guard let index = saves.firstIndex(where: { $0.isSameHold(as: save) }) else { return }
        saves[index].reason = reason
        try write(saves)
    }

    private func read() throws -> [HeldKBSave] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw HeldKBSaveError.storage(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode([HeldKBSave].self, from: data)
        } catch {
            throw HeldKBSaveError.storage("the file does not parse: \(error.localizedDescription)")
        }
    }

    private func write(_ saves: [HeldKBSave]) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(saves).write(to: fileURL, options: .atomic)
        } catch {
            throw HeldKBSaveError.storage(error.localizedDescription)
        }
    }
}

/// Holds an expired-certificate save, and sends held saves through
/// `KnowledgeBase.submitIfCurrent`, the same path a normal signed save takes.
enum HeldKBSaves {
    /// What became of one send attempt.
    enum Outcome: Equatable {
        case sent
        /// The Touch ID or password prompt was dismissed; nothing was signed or sent.
        case cancelled
        /// `kb apply` refused the save, with its stderr, or the attempt failed before
        /// it could be sent. Nothing changed on the knowledge base.
        case refused(String)

        /// The reason a save that did not go out keeps on the list. Nil for `.sent`.
        var reason: String? {
            switch self {
            case .sent: return nil
            case .cancelled: return "The Touch ID prompt was cancelled. Nothing was sent."
            case .refused(let why): return why
            }
        }
    }

    struct SendResult: Equatable, Identifiable {
        let save: HeldKBSave
        let outcome: Outcome

        var id: String { save.id }

        /// One line for the person: what went out, and why what did not.
        var summary: String {
            switch outcome {
            case .sent: return "Sent \(save.documentId)."
            case .cancelled, .refused: return "\(save.documentId) not sent: \(outcome.reason ?? "")"
            }
        }
    }

    /// What a batch of sends did. `results` holds every attempt made before the
    /// batch stopped. `storeError` is set when the store could not record an
    /// outcome, which stops the batch: a send that went out is already on the
    /// knowledge base, so its result stays valid.
    struct SendBatch: Equatable {
        var results: [SendResult]
        var storeError: String?
    }

    /// Records the save as held when, and only when, the certificate was outside
    /// its validity window: the one outcome that waits for a renewed certificate.
    /// No certificate, a cancelled prompt and an unverified round trip never reach
    /// this, or pass through it without a record. `content` is the text written to
    /// `draftPath`, so its hash is the hash of the bytes a later send will read.
    static func holdIfExpired(_ outcome: KnowledgeBase.SignedSaveOutcome,
                              document: KnowledgeBase.CheckedOutDocument,
                              content: String, draftPath: String, heldAt: Date,
                              store: HeldKBSaveStore) throws {
        guard case .outsideValidity = outcome else { return }
        try store.record(HeldKBSave(document: document,
                                    draftSha256: SignedSaveEnvelope.contentSha256Hex(content),
                                    draftPath: draftPath, heldAt: heldAt))
    }

    /// Sends each save in order, one signing prompt each. A save that goes out
    /// leaves the store; one that does not keeps its reason, so a retry can send
    /// it. A cancelled prompt does not stop the rest: each save asks once. Each
    /// send blocks on Touch ID, so call this off the main thread.
    ///
    /// `configuredTargets` is the set of hosts in Deck's Hosts settings. A record
    /// naming any other host is refused. `draftDirectory` gives the working-copy
    /// directory a document's draft must sit in.
    static func send(
        _ saves: [HeldKBSave],
        store: HeldKBSaveStore,
        signingKey: SigningKey,
        certificatePEM: String?,
        configuredTargets: [SSHTarget],
        now: Date = Date(),
        draftDirectory: (String) throws -> URL = { try WorkingCopyStore.directory(forKBId: $0) },
        run: ([String], String?) throws -> Data = { argv, stdin in
            try SessionAgent.run(argv, stdin: stdin)
        }
    ) -> SendBatch {
        var results: [SendResult] = []
        for save in saves {
            let outcome = attempt(save, signingKey: signingKey, certificatePEM: certificatePEM,
                                  configuredTargets: configuredTargets, now: now,
                                  draftDirectory: draftDirectory, run: run)
            results.append(SendResult(save: save, outcome: outcome))
            do {
                if let reason = outcome.reason {
                    try store.setReason(reason, for: save)
                } else {
                    try store.remove(save)
                }
            } catch {
                return SendBatch(results: results, storeError: error.localizedDescription)
            }
        }
        return SendBatch(results: results, storeError: nil)
    }

    /// The Touch ID prompt's text for one held save. It names the document, and
    /// it says that one press signs this save only.
    static func signReason(for save: HeldKBSave) -> String {
        "Send your held save of \(save.documentId) to the Convivy knowledge base. This press signs this save only."
    }

    /// Records that a direct save of `documentId` on `target` reached the knowledge
    /// base, which makes every older hold on it stale, then tells open Settings
    /// lists. A store that cannot be written does not undo the save, so its
    /// error is dropped; a hold left behind is refused on its next send.
    static func clearHoldsAfterDirectSave(documentId: String, target: SSHTarget,
                                          store: HeldKBSaveStore = .shared,
                                          center: NotificationCenter = .default) {
        try? store.removeHolds(documentId: documentId, target: target)
        center.post(name: .heldKBSavesDidChange, object: nil)
    }

    /// Checks the record before anything is signed: the document id must be a
    /// knowledge-base id, the source path must not carry a line break, the host and
    /// user must be valid and configured, the record's draft path must agree with
    /// the one derived from the document id, and the draft at that path must be a
    /// single file in the document's working copy that hashes to the value recorded
    /// at hold time, and the certificate must be inside its window. Each check
    /// refuses with a reason and the signing key is not asked to sign unless all of
    /// them pass.
    private static func attempt(
        _ save: HeldKBSave,
        signingKey: SigningKey,
        certificatePEM: String?,
        configuredTargets: [SSHTarget],
        now: Date,
        draftDirectory: (String) throws -> URL,
        run: ([String], String?) throws -> Data
    ) -> Outcome {
        // The id names the working-copy directory and the Touch ID prompt, so it is
        // checked before either is used.
        guard DeckOpenRef.validateKBId(save.documentId) != nil else {
            return .refused("the saved document id is not a knowledge-base id, so nothing was sent.")
        }

        // `sourceRef` goes into the signed envelope unchanged. `library-protocol`
        // §2.2 has the verifier refuse a path containing a line break, but a record
        // carrying one would otherwise reach the Touch ID prompt before that refusal.
        // `isNewline` is checked per Character because "\r\n" is one Character, so a
        // check for "\n" or "\r" alone misses it.
        guard !save.sourceRef.contains(where: \.isNewline) else {
            return .refused("the saved source path for \(save.documentId) contains a line break, "
                + "so nothing was sent.")
        }

        // The record is read back from disk, so its host and user are checked here
        // before they reach ssh.
        do {
            _ = try validateHostUser(save.user)
            _ = try validateHostAddress(save.host)
        } catch {
            return .refused("the saved host or user is not a valid ssh target, so nothing was sent.")
        }
        guard configuredTargets.contains(save.target) else {
            return .refused("\(save.user)@\(save.host) is not a host in Deck's Hosts settings, so nothing was sent.")
        }

        let directory: URL
        do {
            directory = try draftDirectory(save.documentId)
        } catch {
            return .refused("the working copy for \(save.documentId) could not be found: \(error)")
        }
        // The path read from is the one `saveLocally` would place this document's
        // draft at, not the `draftPath` carried on the record. A record whose
        // `draftPath` disagrees names a file that is not this document's draft,
        // whether through tampering or through drift, and is refused rather than
        // read. `draftPath` only cross-checks; it never chooses what gets opened.
        let derivedPath = KnowledgeBase.draftURL(forKBId: save.documentId, in: directory).path
        guard derivedPath == save.draftPath else {
            return .refused("the saved draft path for \(save.documentId) does not match its working copy, "
                + "so nothing was sent.")
        }
        let content: String
        do {
            content = try HeldDraftFile.readDraft(at: derivedPath, inside: directory)
        } catch let failure as HeldDraftFile.Failure {
            return .refused(HeldDraftFile.reason(for: failure, documentId: save.documentId,
                                                 draftPath: derivedPath))
        } catch {
            return .refused("the local draft at \(derivedPath) could not be read: \(error)")
        }
        guard SignedSaveEnvelope.contentSha256Hex(content) == save.draftSha256 else {
            return .refused("The draft changed after this save was held. Saving the document again "
                + "with a current certificate sends the new text and clears this entry.")
        }

        guard let certificatePEM else {
            return .refused("no signing certificate is stored for this key")
        }
        let document = KnowledgeBase.CheckedOutDocument(
            id: save.documentId, content: content, contentSha: save.contentSha,
            sourceRef: save.sourceRef, target: save.target)
        do {
            switch try KnowledgeBase.submitIfCurrent(
                target: save.target, document: document, content: content,
                signingKey: signingKey, certificatePEM: certificatePEM, now: now,
                signReason: signReason(for: save), run: run) {
            case .sent:
                return .sent
            case .cancelled:
                return .cancelled
            case .refused(let message):
                return .refused(message)
            case .noCertificate:
                return .refused("no signing certificate is stored for this key")
            case .outsideValidity:
                return .refused("the signing certificate is outside its validity window")
            }
        } catch {
            return .refused("\(error)")
        }
    }
}
