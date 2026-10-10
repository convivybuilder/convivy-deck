import SwiftUI
import WebKit

/// The WYSIWYG editor for a Markdown file on the mini — phase 3 of
/// `deck/specs/opening-a-file-from-the-session`.
///
/// ## This is the one pane in Deck that runs script, and everything here follows from that
///
/// The conversation pane and the file viewer both set
/// `allowsContentJavaScript = false` and load an already-rendered page into an
/// opaque origin. The editor cannot: `md-serial`'s editing layer is an ES
/// module, and an opaque origin refuses modules the same way a `file://` URL
/// does. So the page is served over the loopback server phase 2 built, with its
/// four guards and its Content-Security-Policy, and the web view keeps script on.
///
/// Three things stand where `allowsContentJavaScript = false` used to:
///
/// 1. **The server's CSP** confines the page. `connect-src 'self'` and
///    `img-src 'self' data:` mean no `fetch`, `sendBeacon`, image beacon or
///    form post reaches an external host, so nothing in the document can carry
///    the capability token out.
/// 2. **The navigation policy** below refuses every navigation that is not this
///    page's own loopback origin. That closes the one channel the CSP cannot,
///    because `navigate-to` is not a directive WebKit enforces — the residual
///    named in the spec and tracked as `issue_01KZ4N9HVFHEE36TQPCK4XKRPE`.
/// 3. **The bridge is one handler taking two messages** and is the only way the
///    page reaches Swift. `decode` rejects everything else, so a page that
///    posts an unexpected shape gets silence rather than a partial write.
///
/// ## The write is Swift's, not the page's
///
/// The page computes the new Markdown and posts it. Swift decides where it
/// goes, and it goes to the path the pane was opened on — never to a path in
/// the message. That is the whole reason `save` carries a source and no
/// destination.
struct EditorPane: View {
    /// The file being edited. Only `.path` refs reach here; see `canEdit`.
    let ref: DeckOpenRef.Origin
    let appearance: Appearance
    let server: WorkingCopyServer
    /// The host this file was opened from.
    let target: SSHTarget
    /// Every configured host, so a `deck-open:` link the page navigates to
    /// validates against the roots they derive rather than a compiled one —
    /// see `DeckOpenRef.allowedPathRoots(hosts:)`.
    let hosts: [HostEntry]

    /// Leaves the editor for the read-only viewer on the same file.
    let onDone: () -> Void
    /// Closes the column entirely.
    let onClose: () -> Void
    /// A `deck-open:` link clicked inside the document.
    let onOpenRef: (DeckOpenRef.Origin) -> Void

    @StateObject private var model = EditorModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EditorStatusBanner(status: model.status)
            content
        }
        .task(id: PaneLoadIdentity(ref: ref, target: target)) {
            await model.load(ref: ref, appearance: appearance, server: server, target: target)
        }
        .onDisappear { model.releaseLease() }
    }

    // MARK: - Chrome

    /// The header is native, like every other piece of Deck's chrome. The page
    /// carries its own Save button — it is the one thing that knows when the
    /// document model has been rebuilt — and this bar reports what came of it.
    private var header: some View {
        HStack(spacing: 6) {
            Text(EditorPane.title(for: ref))
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.status.label)
                .frameFont(.body)
                .foregroundStyle(model.status.isFailure ? Color.red : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button(action: onDone) { Image(systemName: "eye") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stop editing and read this file")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Close the editor")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// The banner text for `.unverified`, pulled out as a pure function so the
    /// wording — in particular, that it never says "Saved" and always lists
    /// the failures it has — is testable without a view.
    static func unverifiedExplanation(failures: [String]) -> String {
        guard !failures.isEmpty else {
            return "The knowledge base has not yet confirmed this save would come back "
                + "unchanged, so nothing was signed or sent. Your draft is kept on this "
                + "Mac; nothing there has changed."
        }
        let list = failures.map { "• \($0)" }.joined(separator: "\n")
        return "The save could not be verified as faithful, so nothing was signed or sent. "
            + "Your draft is kept on this Mac; nothing there has changed.\n\n\(list)"
    }

    /// The part of the `.certificateOutsideValidity` status that follows
    /// "Not sent to the knowledge base — ". Dates are the certificate's own
    /// UTC dates, so a window that ends at 03:24 UTC on 3 January reads as 3
    /// January on every Mac, whatever its time zone.
    nonisolated static func certificateOutsideValidityExplanation(_ problem: KnowledgeBase.CertificateValidityProblem) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted,
                                     locale: Locale(identifier: "en_GB"),
                                     timeZone: TimeZone(identifier: "UTC")!)
        switch problem {
        case .expired(let notAfter):
            return "your signing certificate expired on \(notAfter.formatted(style)). "
                + "Import a renewed one in Settings › Signing."
        case .notYetValid(let notBefore):
            return "your signing certificate is not valid until \(notBefore.formatted(style)). "
                + "Import a certificate that is valid today in Settings › Signing."
        }
    }

    /// The banner text for `.certificateOutsideValidity`. The header label
    /// carries the same clause, but the header is one line and truncates at
    /// the tail, so the instruction to import a renewed certificate is only
    /// reliably readable here.
    static func certificateOutsideValidityBanner(_ problem: KnowledgeBase.CertificateValidityProblem) -> String {
        "This save was not sent to the knowledge base, because "
            + certificateOutsideValidityExplanation(problem)
            + " Your draft is kept on this Mac; nothing there has changed."
    }

    /// The banner text for `.heldForRenewal`. `reason` is why the last send
    /// attempt did not go out; nil means the save is still waiting for a renewed
    /// certificate.
    static func heldForRenewalBanner(reason: String?) -> String {
        guard let reason else {
            return "This save is held on this Mac. It goes to the knowledge base once a "
                + "renewed signing certificate is imported in Settings › Signing."
        }
        return "This save was not sent. \(reason) It stays held on this Mac; "
            + "retry it in Settings › Signing."
    }

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .loading:
            centred("Opening the editor…", isError: false)
        case .failed(let message):
            centred(message, isError: true)
        case .ready(let url):
            EditorWebView(
                ref: ref,
                target: target,
                pageURL: url,
                appearance: appearance,
                port: server.port,
                hosts: hosts,
                onMessage: { model.receive($0, ref: $1, target: $2) },
                onOpenRef: onOpenRef)
        }
    }

    private func centred(_ text: String, isError: Bool) -> some View {
        Text(text)
            .frameFont(.body)
            .foregroundStyle(isError ? Color.red : .secondary)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
    }

    // MARK: - Eligibility

    /// Whether `ref` can be edited.
    ///
    /// A KB document is editable: it is checked out, edited, saved to a
    /// working copy, and signed and sent to the knowledge base when this Mac
    /// has a signing certificate. Deck itself still never opens a pull
    /// request or pushes a branch — `platform/decisions/0020` reserves the
    /// repository's write credential to the Library, and the write lands
    /// through `kb apply`'s own signature verification, not around it. A
    /// local file must be Markdown, because the editor parses Markdown and a
    /// `.swift` opened in it would round-trip through a model that does not
    /// describe it.
    nonisolated static func canEdit(_ ref: DeckOpenRef.Origin) -> Bool {
        switch ref {
        case .kb:
            return true
        case .path(let absolutePath):
            return (absolutePath as NSString).pathExtension.lowercased() == "md"
        case .item:
            // NOT REACHABLE: an `.item` ref opens `ColumnOccupant.item`
            // directly and never becomes a viewer/editor ref — see
            // `ContentView.openViewer`. `false` is the safe answer if that
            // invariant is ever wrong, since it withholds the edit
            // affordance rather than opening one.
            return false
        }
    }

    nonisolated static func title(for ref: DeckOpenRef.Origin) -> String {
        switch ref {
        case .path(let p): return (p as NSString).lastPathComponent
        case .kb(let id):  return String(id.split(separator: "/").last ?? "doc")
        case .item(let id): return id  // not reachable — see `canEdit`'s `.item` case
        }
    }
}

/// The banner under the editor header, for the statuses a header word cannot
/// carry.
///
/// A STATUS WORD CANNOT CARRY THIS. "Saved on this Mac only" in the header
/// is the right label, but the thing a reader needs to know is what did NOT
/// happen — the knowledge base has not changed and their edit is not
/// queued anywhere. Someone who reads "Saved", closes the window and
/// expects a pull request has lost the edit as surely as if the write had
/// failed. So it gets a banner, in the pane, in full sentences.
///
/// A separate view so the banner can be rendered with a given status, which
/// `EditorPane`'s own model cannot be without loading a page.
struct EditorStatusBanner: View {
    let status: EditorModel.Status

    @ViewBuilder
    var body: some View {
        if case .savedLocally = status {
            Text(KnowledgeBase.notReturnedExplanation)
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .textSelection(.enabled)
        } else if case .refused = status {
            Text("The knowledge base refused this save. Your draft is kept on this Mac; "
                 + "nothing there has changed.")
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .textSelection(.enabled)
        } else if case .unverified(let failures) = status {
            Text(EditorPane.unverifiedExplanation(failures: failures))
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .textSelection(.enabled)
        } else if case .certificateOutsideValidity(let problem) = status {
            Text(EditorPane.certificateOutsideValidityBanner(problem))
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .textSelection(.enabled)
        } else if case .heldForRenewal(let reason) = status {
            Text(EditorPane.heldForRenewalBanner(reason: reason))
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .textSelection(.enabled)
        }
    }
}

// MARK: - The bridge

/// What the page is allowed to say to Swift.
///
/// Two messages, both from one handler named `deckEditor`. `save` is the
/// page's; `dirty` is posted by the user script Deck injects, because the
/// shipped page reports edits to nothing.
enum EditorMessage: Equatable {
    case save(source: String, roundTrip: EditorRoundTrip)
    case dirty
}

/// The upstream verdict on whether a save's Markdown would come back out of
/// `md-serial` unchanged, before Deck signs it.
///
/// `session_view.py`'s bootstrap (`issue_01M3P0A0GSS8MNTPXEV3JBB0JZ`, itself
/// waiting on `md-serial`'s `saveChecked()`, `issue_01M3P0GC237X3QYWYGT2HWTYP3`)
/// is what will fill this in; until it ships, every `save` message on
/// `origin/main`'s editor page carries no `roundTrip` at all, which decodes to
/// `.absent` and refuses to sign, same as an explicit `ok: false`. That is the
/// intended state for every save until both land — see `EditorPane`'s header.
struct EditorRoundTrip: Equatable {
    let ok: Bool
    /// Human-readable, already flattened from whatever shape the page sent —
    /// a string or a `{message, path, ...}` object — because the reader of the
    /// banner is a person, not the page.
    let failures: [String]

    /// What a `save` with no `roundTrip` field, or one that failed to parse,
    /// decodes to. Not-ok with nothing to show, so it reads the same as a
    /// verdict that ran and failed rather than as one that never happened.
    static let absent = EditorRoundTrip(ok: false, failures: [])

    /// What a `.kb` save does with this verdict, decided before anything that
    /// needs Touch ID, a certificate, or a real `kb apply` call runs. A pure
    /// property rather than logic inside `EditorModel.receive` so the gate
    /// itself — sign only on `ok`, everything else reports why not — is
    /// pinned by a test without any of that machinery.
    var gate: EditorSaveGate {
        ok ? .signAndSend : .unverified(failures: failures)
    }
}

/// What `EditorRoundTrip.gate` decides: attempt the sign, or stop and say why.
enum EditorSaveGate: Equatable {
    case signAndSend
    case unverified(failures: [String])
}

extension EditorMessage {
    /// The largest document a save will carry, in UTF-8 bytes.
    ///
    /// A ceiling rather than a limit anyone should meet: the corpus's longest
    /// document is three orders of magnitude under it. It is here so that a
    /// page looping on `postMessage` cannot walk Deck into a memory failure,
    /// and so that an over-long payload fails as a refused save rather than as
    /// a truncated write.
    static let maximumSourceBytes = 8 * 1024 * 1024

    /// Decodes a `WKScriptMessage` body.
    ///
    /// Returns nil for anything that is not one of the two shapes above,
    /// including a `save` with no source, a source over the ceiling, and a body
    /// that is not a dictionary at all. Pure and `nonisolated` so the whole
    /// decision is testable without WebKit.
    nonisolated static func decode(_ body: Any) -> EditorMessage? {
        guard let dictionary = body as? [String: Any],
              let action = dictionary["action"] as? String else { return nil }
        switch action {
        case "dirty":
            return .dirty
        case "save":
            guard let source = dictionary["source"] as? String,
                  source.utf8.count <= maximumSourceBytes else { return nil }
            return .save(source: source, roundTrip: decodeRoundTrip(dictionary["roundTrip"]))
        default:
            return nil
        }
    }

    /// Decodes `roundTrip` leniently: a missing key, a value that is not a
    /// dictionary, or an `ok` that is not a bool all fall back to `.absent`
    /// rather than refusing the whole `save`. The save itself is real and the
    /// draft still deserves to be written; only the signing decision is
    /// withheld. `failures` accepts either strings or objects, since the
    /// upstream shape for a single failure is not pinned by the contract yet.
    nonisolated private static func decodeRoundTrip(_ raw: Any?) -> EditorRoundTrip {
        guard let dictionary = raw as? [String: Any] else { return .absent }
        let ok = dictionary["ok"] as? Bool ?? false
        let failures = (dictionary["failures"] as? [Any] ?? []).map(describeFailure)
        return EditorRoundTrip(ok: ok, failures: failures)
    }

    nonisolated private static func describeFailure(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let path = object["path"] as? String { return path }
            return object.keys.sorted()
                .map { "\($0): \(object[$0] ?? "")" }
                .joined(separator: ", ")
        }
        return "\(value)"
    }
}

// MARK: - Model

@MainActor
final class EditorModel: ObservableObject {
    enum Page {
        case loading
        case failed(String)
        case ready(URL)
    }

    enum Status: Equatable {
        case clean
        case edited
        case saving
        /// Signed and accepted by `kb apply`, recorded as the certificate's
        /// person.
        case saved
        /// Written to the working copy on this Mac, and nowhere else — no
        /// certificate stored yet, or the Touch ID prompt was cancelled.
        case savedLocally
        /// Written to the working copy on this Mac, but never signed or sent:
        /// the upstream round-trip verdict was absent, malformed, or `ok:
        /// false`. Distinct from `savedLocally` because that case did attempt
        /// the sign and chose not to send for a reason that has nothing to do
        /// with the document's own fidelity; this one never attempted it.
        case unverified(failures: [String])
        /// Signed, sent, and refused by `kb apply`. The draft written before
        /// the attempt is kept; nothing on the knowledge base changed.
        case refused(String)
        /// Written to the working copy on this Mac, but not signed or sent: the
        /// stored certificate's validity window does not include now. The draft
        /// is kept, and the save goes out once a renewed certificate is imported
        /// — a separate change, not this one.
        case certificateOutsideValidity(KnowledgeBase.CertificateValidityProblem)
        /// Held for a renewed certificate (`HeldKBSaves`). `reason` is why the last
        /// send attempt did not go out; nil before any attempt.
        case heldForRenewal(reason: String?)
        case failed(String)

        var label: String {
            switch self {
            case .clean:             return ""
            case .edited:            return "Unsaved changes"
            case .saving:            return "Saving…"
            case .saved:             return "Saved"
            case .savedLocally:      return "Saved on this Mac only"
            case .unverified(let failures):
                return failures.isEmpty
                    ? "Not verified yet — saved on this Mac only"
                    : "Not verified as a faithful round trip — saved on this Mac only"
            case .refused(let text): return "Not sent to the knowledge base — \(text)"
            case .certificateOutsideValidity(let problem):
                return "Not sent to the knowledge base — "
                    + EditorPane.certificateOutsideValidityExplanation(problem)
            case .heldForRenewal(let reason):
                return "Not sent to the knowledge base — "
                    + (reason ?? "held until a renewed certificate is imported")
            case .failed(let text):  return "Not saved — \(text)"
            }
        }

        var isFailure: Bool {
            switch self {
            case .failed, .refused, .certificateOutsideValidity, .heldForRenewal: return true
            case .unverified(let failures): return !failures.isEmpty
            default: return false
            }
        }
    }

    @Published var page: Page = .loading
    @Published var status: Status = .clean

    /// The KB document this pane checked out, when the ref is a KB one.
    ///
    /// Held for its content, its `sourceRef` and its sha — what `submit`
    /// signs a save's envelope over — and so a save is addressed to the
    /// document the pane actually holds rather than to whatever the message
    /// claims.
    private var checkedOut: KnowledgeBase.CheckedOutDocument?

    /// The file currently loaded. The model outlives a change of `ref` — it is
    /// a `@StateObject` on a view whose identity does not change — so a save
    /// that returns after the pane has moved on must not report itself against
    /// whatever is on screen now. The write still lands where it was addressed;
    /// only the status is withheld.
    private var loadedRef: DeckOpenRef.Origin?

    /// Follows Settings › Signing: when a held save is sent or refused, the banner
    /// for the same document follows. Cancelled with the model.
    nonisolated(unsafe) private var heldObserver: Task<Void, Never>?

    init() {
        heldObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .heldKBSavesDidChange) {
                self?.heldSavesChanged()
            }
        }
    }

    deinit {
        heldObserver?.cancel()
    }

    func load(ref: DeckOpenRef.Origin, appearance: Appearance,
              server: WorkingCopyServer, target: SSHTarget) async {
        // RELEASE BEFORE ACQUIRING, because this model outlives a load. The
        // pane's `.task(id:)` refires on a ref change and, since #131, on a
        // target change too, both without the view disappearing — and
        // `.onDisappear` is the only other place a lease is dropped. Assigning
        // `checkedOut` over a live checkout therefore stranded the previous
        // one for its full four hours, every time, no race required. Released
        // against the DOCUMENT's own target rather than the incoming one,
        // which is what `releaseLease` already does and why it is reused here
        // rather than open-coded: the lease being dropped belongs to the host
        // it was taken from, not to the host being switched to.
        releaseLease()
        page = .loading
        status = .clean
        loadedRef = ref

        do {
            let localURL: URL
            switch ref {
            case .path(let remotePath):
                localURL = try await Task.detached {
                    let html = try SessionAgent.renderEditor(target: target, path: remotePath,
                                                             appearance: appearance)
                    return try WorkingCopyStore.writeEditorPage(
                        html, forAbsolutePath: remotePath)
                }.value
            case .kb(let id):
                // CHECKOUT FIRST, AND RECORD IT BEFORE ANYTHING ELSE CAN THROW.
                // Checkout takes a lease; the render that follows can fail. When
                // both lived in one detached closure, a render failure threw
                // before `checkedOut` was ever assigned, so `releaseLease` found
                // nil and skipped a lease that had already been taken — held for
                // four hours against a document the reader could not even open.
                // Found by `deck-reviewer`; the two steps are separated so the
                // thing that tracks the lease cannot be skipped by the step
                // after it.
                let document = try await Task.detached {
                    try KnowledgeBase.checkout(target: target, id: id)
                }.value
                checkedOut = document
                // A save held by an earlier launch still waits on this document; say so on open.
                do {
                    if let held = try heldSave(id: id, target: document.target) {
                        status = .heldForRenewal(reason: held.reason)
                    }
                } catch {
                    status = .failed("\(error)")
                }
                localURL = try await Task.detached {
                    let html = try SessionAgent.renderEditor(
                        target: target, content: document.content, name: id, appearance: appearance)
                    return try WorkingCopyStore.writeEditorPage(html, forKBId: id)
                }.value
            case .item(let id):
                // NOT REACHABLE: `EditorPane.canEdit` refuses `.item` refs,
                // so `ContentView` never constructs this pane with one.
                // Thrown so a future caller that slips past that check gets
                // this pane's own failure state instead of a crash.
                throw WorkingCopyStore.FetchError.unexpectedResponse(
                    "item ref reached the editor (id: \(id)) — this should open the item pane instead")
            }
            guard let url = server.url(for: localURL) else {
                page = .failed("The local file server is not running, so the "
                               + "editor cannot load. Reopen Deck to restart it.")
                return
            }
            page = .ready(url)
        } catch {
            page = .failed("Could not open the editor: \(error)")
        }
    }

    /// Acts on one decoded message.
    ///
    /// `ref` is the file the web view had loaded when the message arrived, not
    /// a path from the message — the page says what to write, never where. It
    /// is also not the pane's current ref, which is what makes a save from a
    /// page the reader has already left land on its own file rather than on
    /// the one now on screen.
    func receive(_ message: EditorMessage, ref: DeckOpenRef.Origin, target: SSHTarget) {
        switch message {
        case .dirty:
            // A save in flight already reflects these bytes; overwriting its
            // status with "Unsaved changes" would report the wrong thing for
            // the length of the round trip.
            if status != .saving { report(.edited, for: ref) }
        case .save(let source, let roundTrip):
            if case .kb(let id) = ref {
                // THE CHECKOUT HAS TO MATCH THE PAGE THAT SENT THIS, not
                // merely exist. `ref` and `target` travel with the page the
                // coordinator holds; `checkedOut` is a model field that
                // `load` reassigns. The coordinator sets `loaded` before it
                // calls `view.load`, so between those two the outgoing page's
                // JS is still live while `loaded` already names the incoming
                // one — a save fired in that window arrives attributed to the
                // NEW ref and target. Without this guard the `.kb` branch
                // would then write the old page's bytes into the new
                // checkout, since `saveLocally` addresses the document it is
                // handed rather than the ref. Reachable since a host switch
                // on the same doc id started refiring `load` at all, which is
                // what this PR does. The `.path` branch has no equivalent
                // hole: it addresses its write from `ref` and `target`
                // directly. Found by `deck-security-reviewer` on #131.
                guard let document = checkedOut,
                      document.id == id, document.target == target else {
                    status = .failed("this document was not checked out")
                    return
                }
                status = .saving
                Task {
                    let draftURL: URL
                    do {
                        draftURL = try await Task.detached {
                            try KnowledgeBase.saveLocally(document: document,
                                                          content: source)
                        }.value
                    } catch {
                        report(.failed("\(error)"), for: ref)
                        return
                    }
                    // GATED ON THE UPSTREAM VERDICT, NOT ATTEMPTED AND THEN
                    // DISCARDED. Signing requires Touch ID; running that
                    // prompt for a save the round-trip check has already
                    // rejected would ask the person to authorize a write that
                    // is refused before their press could matter. See
                    // `EditorRoundTrip.gate`.
                    switch roundTrip.gate {
                    case .unverified(let failures):
                        report(.unverified(failures: failures), for: ref)
                        return
                    case .signAndSend:
                        break
                    }
                    let outcome = await Task.detached {
                        Self.signAndSubmit(document: document, content: source)
                    }.value
                    switch outcome {
                    case .sent:
                        // The save is already on the knowledge base, so a store that cannot be
                        // written does not undo it. A hold left behind is refused on its next send
                        // as changed since held, and Settings keeps it listed with that reason.
                        HeldKBSaves.clearHoldsAfterDirectSave(documentId: id, target: target)
                        report(.saved, for: ref)
                    case .noCertificate, .cancelled:
                        report(.savedLocally, for: ref)
                    case .outsideValidity(let problem):
                        // Held durably before the banner says so: a hold that is not
                        // recorded would never be sent after the renewal.
                        do {
                            try HeldKBSaves.holdIfExpired(outcome, document: document,
                                                          content: source, draftPath: draftURL.path,
                                                          heldAt: Date(), store: .shared)
                            report(.certificateOutsideValidity(problem), for: ref)
                        } catch {
                            report(.refused("the save is kept on this Mac, but could not be "
                                            + "queued for the knowledge base: \(error)"), for: ref)
                        }
                    case .refused(let message):
                        report(.refused(message), for: ref)
                    }
                }
                return
            }
            guard case .path(let remotePath) = ref else {
                status = .failed("this file has no path to save to")
                return
            }
            status = .saving
            Task {
                do {
                    try await Task.detached {
                        try WorkingCopyStore.writeBack(target: target, source: source,
                                                       toAbsolutePath: remotePath)
                    }.value
                    report(.saved, for: ref)
                } catch {
                    report(.failed("\(error)"), for: ref)
                }
            }
        }
    }

    /// Signs and sends the draft already on disk, or reports why it stayed
    /// local. Runs off the main thread: signing blocks on Touch ID.
    ///
    /// Loads the key without creating one — key creation is Settings'
    /// `SigningKeySettingsView` job, prompted for on purpose, not something a
    /// save should trigger silently. No key, no certificate, or a certificate for
    /// a different key reads the same as `.noCertificate`: either way there is
    /// nothing this Mac can honestly sign with yet.
    nonisolated private static func signAndSubmit(
        document: KnowledgeBase.CheckedOutDocument, content: String
    ) -> KnowledgeBase.SignedSaveOutcome {
        guard let signingKey = try? SigningKeyStore(
                fileURL: SigningKeyStore.defaultFileURL(),
                factory: SecureEnclaveSigningKeyFactory()).load() else {
            return .noCertificate
        }
        let spki = CertificateSigningRequest.subjectPublicKeyInfo(x963: signingKey.publicKeyX963)
        guard let certificatePEM = SigningCertificateStore(
                fileURL: SigningCertificateStore.defaultFileURL()).loadPEM(forSPKI: spki) else {
            return .noCertificate
        }
        do {
            // The validity window is checked inside `submitIfCurrent`, before
            // `submit` signs, so an expired certificate never reaches the key.
            return try KnowledgeBase.submitIfCurrent(
                target: document.target, document: document, content: content,
                signingKey: signingKey, certificatePEM: certificatePEM, now: Date())
        } catch {
            return .refused("\(error)")
        }
    }

    /// Drops the lease when the pane goes away, so an abandoned edit does not
    /// hold one for its full four hours. This is the only release there is: a
    /// signed save that lands does not drop it either, because the lease is
    /// advisory dedup rather than a gate `submit` needs to clear (see
    /// `KnowledgeBase.releaseArguments`).
    func releaseLease() {
        guard let document = checkedOut else { return }
        checkedOut = nil
        Task.detached { KnowledgeBase.release(target: document.target, id: document.id) }
    }

    /// Publishes a save's outcome, but only while the pane still holds the file
    /// it was addressed to.
    private func report(_ outcome: Status, for ref: DeckOpenRef.Origin) {
        guard loadedRef == ref else { return }
        status = outcome
    }

    /// Settings sent or refused a held save. An open document that still has a
    /// held save shows its newest reason. One whose held save is gone was sent,
    /// so a banner that said "held" or "not sent to the knowledge base" becomes "Saved".
    private func heldSavesChanged() {
        guard case .kb(let id) = loadedRef, let target = checkedOut?.target else { return }
        do {
            if let held = try heldSave(id: id, target: target) {
                status = .heldForRenewal(reason: held.reason)
                return
            }
            switch status {
            case .heldForRenewal, .certificateOutsideValidity: status = .saved
            default: break
            }
        } catch {
            status = .failed("\(error)")
        }
    }

    /// The held save for `id` at `target`, if one waits on it.
    private func heldSave(id: String, target: SSHTarget) throws -> HeldKBSave? {
        try HeldKBSaveStore.shared.all()
            .first(where: { $0.documentId == id && $0.target == target })
    }
}

// MARK: - Web view

/// The navigation the editor's web view will allow.
///
/// Split out as a pure enum and a pure function so the policy is testable
/// without a window, a server, or a page — the same seam `DeckOpenRef.validate`
/// uses, and for the same reason: this decides what the app will load.
enum EditorNavigation: Equatable {
    case allow
    case cancel
    case external(URL)
    case openRef(DeckOpenRef.Origin)
}

/// Everything crossing the boundary between the generated page and Swift: the
/// handler name, the script Deck injects, the appearance restamp, and what the
/// page is allowed to navigate to.
///
/// A named type rather than four statics on the web view, because this is the
/// half of the editor-page contract Deck owns. Anything here that changes is a
/// change to that contract, and the contract doc says so.
enum EditorPageBridge {
    /// The one message handler. The page's own bootstrap posts `save` to it;
    /// `dirtyScript` posts `dirty`.
    static let handlerName = "deckEditor"

    /// Reports the first and every subsequent edit back to Swift.
    ///
    /// The page surfaces no edit state to anything: `mountEditor()` returns
    /// `isDirtySinceMount()` and `revision()`, but the page's bootstrap binds
    /// only `save`, so neither reaches Swift and nothing posts them. Rather
    /// than ask the page to grow a second message, Deck listens for the same
    /// `input` events the editor does. `#editor-root` is the element the page
    /// mounts on, pinned by the editor-page contract.
    static let dirtyScript = """
    (function () {
      var root = document.getElementById('editor-root');
      if (!root) { return; }
      root.addEventListener('input', function () {
        window.webkit.messageHandlers.deckEditor.postMessage({ action: 'dirty' });
      });
    })();
    """

    /// Restamps the resolved appearance onto `<html>`.
    ///
    /// A RESTAMP RATHER THAN A RELOAD, and that is the whole point. The page is
    /// generated with `--theme`, so the first paint is already right; a theme
    /// change afterwards only needs the attribute moved. Re-rendering and
    /// reloading would be simpler and would throw away whatever the reader had
    /// typed, which is not a trade a colour change gets to make.
    static func themeScript(for appearance: Appearance) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        return "document.documentElement.setAttribute('data-theme','\(theme)')"
    }

    /// What to do with a navigation the page attempted.
    ///
    /// Everything that is not this page's own loopback origin is refused. A
    /// `deck-open:` link routes to Deck; a link the reader clicked whose scheme
    /// `ExternalLink` will open goes to their browser. Anything else — a
    /// `file://` URL, a redirect to another host, a form target, a
    /// script-driven navigation — is cancelled, and that is what closes the
    /// token-in-the-URL exfiltration channel the CSP cannot.
    nonisolated static func policy(for url: URL?, isLinkActivated: Bool,
                                   port: UInt16, hosts: [HostEntry]) -> EditorNavigation {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == "deck-open" {
            return DeckOpenRef.validate(url, hosts: hosts).map { .openRef($0) } ?? .cancel
        }
        // `port > 0` first: a listener that has not come up reports 0, and a URL
        // with no port also reads as 0, so without this a bare
        // `http://127.0.0.1/` would be allowed before the server existed.
        if port > 0, scheme == "http", url.host == "127.0.0.1", url.port == Int(port) {
            return .allow
        }
        // The reader's own click, and only for a scheme `ExternalLink` opens.
        // Deciding it here rather than handing everything over means the pane
        // does not depend on an allowlist two layers away to refuse `file://`.
        if isLinkActivated, ExternalLink.allowedSchemes.contains(scheme) {
            return .external(url)
        }
        return .cancel
    }
}

/// What a web view currently holds: the page it loaded, and the file that page
/// was generated from.
///
/// ONE VALUE, BECAUSE THE TWO MUST NEVER MOVE SEPARATELY. A save arriving from
/// the page is addressed by the ref beside the URL it came from. Keeping them
/// as two properties invites a window where one has been updated and the other
/// has not, and the cost of landing in that window is one document's contents
/// written into another document's path.
struct LoadedEditorPage: Equatable {
    let url: URL
    let ref: DeckOpenRef.Origin
    /// The host this page was fetched from, carried with the page rather than
    /// read off the model when a message arrives.
    ///
    /// A save message crosses a WebKit IPC hop, and `.task(id:)` restarts
    /// asynchronously relative to it, so a save queued from the previous
    /// host's page could be handled after a switch had already moved a
    /// model-held field — writing one host's content to the same path on
    /// another. The ref was already carried here for the same reason; the
    /// host is the other half of "which file did this message come from".
    let target: SSHTarget

    /// The page to load, or nil when the view already holds it.
    ///
    /// EVERY FIELD DECIDES, NOT THE URL ALONE. An earlier version compared URLs,
    /// on the reasoning that the URL is derived from the ref and so stands in
    /// for it. That reasoning was only as good as the derivation, and the
    /// derivation collided: two remote paths could map to one working-copy
    /// directory, so switching between them issued no load, the view kept
    /// showing the first file, and a save from it carried the first file's ref.
    /// `WorkingCopyStore.slug` is injective now and that alone would fix it, but
    /// comparing the whole value costs nothing and does not depend on a property
    /// of a function in another type. Found by `deck-security-reviewer` on #74.
    ///
    /// The same argument carried the host in later: a working copy is keyed on
    /// the ref alone, so the same document on two hosts shares one URL, and
    /// comparing the whole value is what makes a host switch reload rather
    /// than keep the first host's page.
    ///
    /// A pure function so the rule is pinned by a test rather than inferred from
    /// where the assignments happen to sit.
    static func toLoad(current: LoadedEditorPage?,
                       wanted: LoadedEditorPage) -> LoadedEditorPage? {
        current == wanted ? nil : wanted
    }
}

/// The inner `WKWebView`. Script is on; see `EditorPane`'s header for what
/// stands in place of turning it off.
private struct EditorWebView: NSViewRepresentable {
    let ref: DeckOpenRef.Origin
    /// The host the page was fetched from, carried into `LoadedEditorPage` so
    /// a message is attributed to a host as well as to a file.
    let target: SSHTarget
    let pageURL: URL
    let appearance: Appearance
    let port: UInt16
    let hosts: [HostEntry]
    /// Carries the ref the coordinator loaded, NOT the one this struct holds.
    /// The struct is rebuilt on every render; the coordinator's ref moves only
    /// when a page is actually loaded, which is what makes it the honest
    /// answer to "which file did this message come from".
    let onMessage: (EditorMessage, DeckOpenRef.Origin, SSHTarget) -> Void
    let onOpenRef: (DeckOpenRef.Origin) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A WEAK PROXY, NOT THE COORDINATOR. `add(_:name:)` retains its handler
        // strongly and the configuration is owned by the web view, so handing it
        // the coordinator — which the view hierarchy also owns — leaks a web
        // view every time the column occupant changes.
        config.userContentController.add(WeakScriptMessageHandler(context.coordinator),
                                         name: EditorPageBridge.handlerName)
        config.userContentController.addUserScript(
            WKUserScript(source: EditorPageBridge.dirtyScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(
            LoadedEditorPage(url: pageURL, ref: ref, target: target), in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.onOpenRef = onOpenRef
        context.coordinator.port = port
        context.coordinator.hosts = hosts
        context.coordinator.load(
            LoadedEditorPage(url: pageURL, ref: ref, target: target), in: view)
        context.coordinator.apply(appearance: appearance, to: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(port: port, appearance: appearance, hosts: hosts,
                    onMessage: onMessage, onOpenRef: onOpenRef)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onMessage: (EditorMessage, DeckOpenRef.Origin, SSHTarget) -> Void
        var onOpenRef: (DeckOpenRef.Origin) -> Void
        var port: UInt16
        var hosts: [HostEntry]
        private var appearance: Appearance

        /// The page this view actually holds. A message is attributed to this
        /// rather than to whatever the enclosing struct was rebuilt with, so a
        /// save cannot be addressed to a file the reader moved on to.
        private var loaded: LoadedEditorPage?

        init(port: UInt16, appearance: Appearance, hosts: [HostEntry],
             onMessage: @escaping (EditorMessage, DeckOpenRef.Origin, SSHTarget) -> Void,
             onOpenRef: @escaping (DeckOpenRef.Origin) -> Void) {
            self.port = port
            self.appearance = appearance
            self.hosts = hosts
            self.onMessage = onMessage
            self.onOpenRef = onOpenRef
        }

        @MainActor
        func load(_ page: LoadedEditorPage, in view: WKWebView) {
            guard let next = LoadedEditorPage.toLoad(current: loaded, wanted: page) else {
                return
            }
            loaded = next
            view.load(URLRequest(url: next.url))
        }

        @MainActor
        func apply(appearance new: Appearance, to view: WKWebView) {
            guard appearance != new else { return }
            appearance = new
            view.evaluateJavaScript(EditorPageBridge.themeScript(for: new))
        }

        /// The page finished loading after a theme change that arrived while it
        /// was still in flight. Restamping here is what stops that change being
        /// lost.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(EditorPageBridge.themeScript(for: appearance))
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            switch EditorPageBridge.policy(
                for: navigationAction.request.url,
                isLinkActivated: navigationAction.navigationType == .linkActivated,
                port: port, hosts: hosts
            ) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .external(let url):
                ExternalLink.open(url)
                decisionHandler(.cancel)
            case .openRef(let ref):
                onOpenRef(ref)
                decisionHandler(.cancel)
            }
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == EditorPageBridge.handlerName,
                  let page = loaded,
                  let decoded = EditorMessage.decode(message.body) else { return }
            onMessage(decoded, page.ref, page.target)
        }
    }
}

/// Holds a script message handler weakly.
///
/// `WKUserContentController.add(_:name:)` retains its handler for the lifetime
/// of the configuration, which the web view owns. Registering an object the
/// view hierarchy also owns therefore builds a cycle that outlives the pane.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
