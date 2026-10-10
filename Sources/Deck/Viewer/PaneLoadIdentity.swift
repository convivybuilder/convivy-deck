import Foundation

/// What a pane's `.task(id:)` reloads on: the file and the host it came from.
///
/// `FileViewerPane` and `EditorPane` both resolve `ref` against `target`
/// inside the task body, so a target change must refire the load the same
/// way a ref change does. Keying `.task(id:)` on `ref` alone — as #119 left
/// it after threading `target` into the closures without adding it to the
/// task's identity — means switching hosts on a `columnOccupant` selection
/// that resolves to the same `Origin` (a KB doc id, which is a shared
/// namespace across hosts) leaves the `@StateObject` in place, the task
/// never refires, and the pane goes on showing the first host's content.
struct PaneLoadIdentity: Equatable {
    let ref: DeckOpenRef.Origin
    let target: SSHTarget
}
