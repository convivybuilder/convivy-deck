import SwiftUI

/// A hand-made tmux window (`ctrl-A c`), drawn as a terminal-only leaf under
/// the session that owns it — `deck/specs/multiple-sessions-per-project`
/// §"Windows created by hand" and §"The rail" (the `⊞` glyph). No dot and no
/// theme menu: a second agent started by hand in this window is exactly the
/// state `claude_pane` cannot read, so there is no liveness to draw and
/// nothing here to retheme — only the raw terminal, and the one act this row
/// offers beyond selecting it, promoting the window to its own session.
struct WindowLeafRow: View {
    let window: Int
    let isSelected: Bool
    let accent: RGB
    let appearance: Appearance
    /// The Builder Default ground this row is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    /// How far this leaf indents, in points beyond the row's own leading
    /// padding — one level deeper than the row that owns it (design
    /// §"The rail"): a crew's own extra window sits where its
    /// pinned/discovered children do, and a child's own extra window sits
    /// one level deeper than that child.
    let indent: CGFloat
    /// True when this is the last row in its owning session's own window
    /// list — see `RailChildSpine`.
    var isLast: Bool = false
    let onMoveToOwnSession: () -> Void
    /// True in the 44pt dot rail — see `RailRow.isCollapsed`'s doc, which
    /// this mirrors.
    var isCollapsed: Bool = false
    /// The window a rollover's successor is starting in, while the owning
    /// session is `rolling` — see `successorWindow(of:)`. The leaf for that
    /// window is labelled as the successor, so a rotation reads as one event
    /// rather than as an unexplained second window.
    var successorWindow: Int? = nil

    private var backing: RGB {
        RailRow.markBacking(appearance: appearance, isSelected: isSelected, accent: accent,
                            ground: statusGround)
    }

    private var isSuccessor: Bool { window == successorWindow }

    /// The leaf's label. A PURE FUNCTION, pinned by a test.
    nonisolated static func title(window: Int, successorWindow: Int?) -> String {
        window == successorWindow ? "rolling over here" : "window \(window)"
    }

    /// The successor's window, only while the rotation is under way. A stale
    /// `successor_window` left on any other state never labels a leaf.
    nonisolated static func successorWindow(of rollover: SessionState.Rollover?) -> Int? {
        guard let rollover, rollover.state == .rolling else { return nil }
        return rollover.successorWindow
    }

    var body: some View {
        let title = WindowLeafRow.title(window: window, successorWindow: successorWindow)
        HStack(spacing: 8) {
            Text("⊞")
                .frameFont(.primary)
                .foregroundStyle(.secondary)
                .frame(width: 10)
            if !isCollapsed {
                Text(title)
                    .frameFont(.primary)
                    // The successor's label takes the attention ink the
                    // predecessor's "rolling" glyph uses, so the two rows read
                    // as one rotation.
                    .foregroundStyle(isSuccessor
                                     ? AnyShapeStyle(Color(ThemeRecipe.attentionInk(on: backing)))
                                     : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, isCollapsed ? 0 : RailRow.leadingPadding + indent)
        .padding(.trailing, isCollapsed ? 0 : 12)
        .frame(maxWidth: isCollapsed ? .infinity : nil)
        .frame(height: RailRow.rowHeight)
        .help(isCollapsed ? title : (isSuccessor ? "The session above continues in this window once its rollover finishes." : ""))
        .background(isSelected ? Color(accent).opacity(0.15) : Color.clear)
        .railChildSpine(indent: indent, isLast: isLast)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move to its own session", action: onMoveToOwnSession)
        }
    }
}
