import Foundation

/// The Library reference-document checkouts the editor currently holds live
/// — reference-counted per document, host and holder (CQ·187, CQ·193).
/// `EditorModel.load` registers one the moment its own checkout lands, and
/// `releaseLease` unregisters it before handing the checkout back.
///
/// The count, not a plain set, is what CQ·193 added: `Deck`'s windows are a
/// plain `WindowGroup`, so the same document can be open in two panes under
/// the same holder at once, each with its own `EditorModel` taking its own
/// `LibraryClient.checkoutReferenceDocument` call. A set with one entry per
/// key could not tell two panes' claims apart, so the first pane to close
/// unregistered the key outright and the Library checkin that followed
/// pulled the checkout out from under the second, still-open pane. The count
/// is what `releaseLease` reads to check in only when the pane releasing it
/// is the last one still claiming that key.
///
/// `HeldKBSaves.attempt` reads this before checking a resend's own checkout
/// back in. A held save is resent later, often after the editor pane that
/// held it has closed and checked its own checkout in — but not always: the
/// reader can reopen the document and keep editing while an earlier hold for
/// it still waits on a renewed certificate. Without this, the resend's own
/// checkin would hand back a lock an open editor still depends on, and its
/// next save would be refused at admission with no live checkout held.
///
/// A plain lock rather than actor isolation: `EditorModel` calls in from the
/// main actor, `HeldKBSaves.attempt` from a detached task, and neither side
/// needs to await the other.
final class LibraryCheckoutRegistry: @unchecked Sendable {
    static let shared = LibraryCheckoutRegistry()

    private struct Key: Hashable {
        let documentId: String
        let target: SSHTarget
        let holder: String
    }

    private let lock = NSLock()
    private var counts: [Key: Int] = [:]

    /// Records one more pane's claim on this key.
    func register(documentId: String, target: SSHTarget, holder: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(documentId: documentId, target: target, holder: holder)
        counts[key, default: 0] += 1
    }

    /// Drops one pane's own claim on this key, never another pane's.
    ///
    /// Returns whether that claim was the last one on this key — the signal
    /// `releaseLease` needs to decide whether checking the Library's own
    /// checkout back in is safe, rather than pulling it out from under a
    /// second pane still claiming the same document, host and holder.
    @discardableResult
    func unregister(documentId: String, target: SSHTarget, holder: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(documentId: documentId, target: target, holder: holder)
        guard let count = counts[key], count > 1 else {
            counts.removeValue(forKey: key)
            return true
        }
        counts[key] = count - 1
        return false
    }

    func isHeld(documentId: String, target: SSHTarget, holder: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (counts[Key(documentId: documentId, target: target, holder: holder)] ?? 0) > 0
    }
}
