import SwiftUI

/// Deck's own find bar — one native control driving whichever backend the
/// session pane currently shows, the conversation's `WKWebView.find` or the
/// terminal's SwiftTerm search (issue_01M1S525RMHB9ENTG8DKM24VS6, the last
/// child of the text-search epic). Themed from the design tokens rather than
/// vendoring SwiftTerm's `MacFindBarView`, which is not `public` and would
/// also be the one control in the window ignoring the theme.
///
/// `ConversationFindBar` and `TerminalFindBar` below are the two backend-
/// specific wrappers; both draw this same row, so the bar reads identically
/// regardless of which surface is live. Neither wrapper reaches into the
/// other's backend.
private struct FindBarRow: View {
    @ObservedObject var state: FindBarState
    let resultsLabel: String
    let hasMatches: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $state.term)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(onNext)
                .frame(minWidth: 80)
            Text(resultsLabel)
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Button {
                onPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!hasMatches)
            .help("Previous match (⇧⌘G)")
            Button {
                onNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(!hasMatches)
            .help("Next match (⌘G)")
            Divider().frame(height: 14)
            Button {
                state.closeAndClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { isFocused = true }
        .onChange(of: state.focusToken) { _, _ in isFocused = true }
        // SCOPED TO THIS ROW'S OWN LIFETIME, the same discipline `OptionCard`
        // uses for ⌘1–9 (`SessionPaneView.swift`): these bindings exist in
        // the view tree only while a find bar is actually mounted, so
        // closing it — Esc, the button above, or a surface switch tearing
        // this view down — removes ⌘G/⇧⌘G/Esc outright rather than leaving a
        // `.disabled` control that could still swallow the key equivalent.
        // ⌘F itself is NOT here: it has to exist while the bar is CLOSED, to
        // open it — see `ContentView`'s own binding, scoped instead to a
        // searchable surface being on screen.
        .background {
            Button("") { onNext() }
                .keyboardShortcut("g", modifiers: .command)
                .hidden()
            Button("") { onPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .hidden()
            Button("") { state.closeAndClear() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }
}

/// Drives the find bar against the conversation's `WKWebView.find` backend.
/// Placed inside `SessionPaneView`, the only holder of the
/// `ConversationScrollState` this needs — see that view's `body` for where
/// this is inserted, above the transcript and below the status bar.
struct ConversationFindBar: View {
    @ObservedObject var state: FindBarState
    @ObservedObject var scrollState: ConversationScrollState

    var body: some View {
        FindBarRow(state: state,
                   resultsLabel: scrollState.resultsLabel,
                   hasMatches: scrollState.searchTotal > 0,
                   onNext: scrollState.findNext,
                   onPrevious: scrollState.findPrevious)
            .onChange(of: state.term) { _, newValue in scrollState.search(newValue) }
            // Runs whether this view is leaving because the bar closed or
            // because the pane switched to Terminal View — either way the
            // highlight belongs to a surface nobody is about to be looking
            // at. `state.term` clears alongside it so the field does not
            // keep showing text the other backend was never asked about.
            .onDisappear {
                scrollState.clearSearch()
                state.term = ""
            }
    }
}

/// The terminal-side mirror of `ConversationFindBar`, driving
/// `TerminalSearchController`'s `next`/`previous`. Placed by `ContentView`
/// beside the main pane's `TerminalPaneView`, which is where the controller
/// this needs is owned — `TerminalPaneView.searchController` is caller-
/// injected, unlike the conversation's own private scroll state.
struct TerminalFindBar: View {
    @ObservedObject var state: FindBarState
    @ObservedObject var controller: TerminalSearchController

    var body: some View {
        FindBarRow(state: state,
                   resultsLabel: controller.resultsLabel,
                   hasMatches: controller.total > 0,
                   onNext: controller.next,
                   onPrevious: controller.previous)
            .onChange(of: state.term) { _, newValue in controller.search(newValue) }
            .onDisappear {
                controller.clear()
                state.term = ""
            }
    }
}
