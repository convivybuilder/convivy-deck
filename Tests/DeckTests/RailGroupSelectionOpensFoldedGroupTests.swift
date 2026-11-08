import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// E24's "Selection" rule (CQ·183): selecting a member of a folded group
/// opens it, whatever set `selection`. `RailView`'s own
/// `.keyboardShortcut` binding is not reachable without a view-level test
/// target — the same limit `RailGateShortcutSuppressionTests` already
/// documents — so this exercises the mechanism every source writes
/// through (`RailView`'s `.onChange(of: selection)`) with the exact ref
/// each source actually constructs: `SessionRef.owned(by:name:)` for
/// Cmd-1…9's hidden buttons, and `StartPicker.choose`'s `.select` case for
/// a running START entry. The physical key equivalent and popover click
/// are a hand-check, the same as that file's own key-equivalent.
@MainActor
final class RailGroupSelectionOpensFoldedGroupTests: XCTestCase {
    /// Carries `selection` so a test can set it from outside the mounted
    /// view, after `RailView` has already laid out — `@State` alone has no
    /// seam for that from outside its own view.
    private final class SelectionHolder: ObservableObject {
        @Published var selection: SessionRef?
    }

    private struct Harness: View {
        @ObservedObject var holder: SelectionHolder
        let crews: [Crew]
        let groups: [CrewGroup]
        let onSetGroupFolded: (CrewGroup, Bool) -> Void

        var body: some View {
            RailView(
                crews: crews,
                groups: groups,
                onSetGroupFolded: onSetGroupFolded,
                accent: { _ in RGB(red: 0, green: 0, blue: 0) },
                mark: { _ in .unpolled },
                isStopped: { _ in false },
                hasOpenGate: { _ in false },
                isTerminalOnly: { _ in false },
                themeMenu: { _ in AnyView(EmptyView()) },
                catalog: [],
                onLaunch: { _ in },
                appearance: .light,
                discoveredSessions: [],
                onMoveWindowToOwnSession: { _, _, _ in },
                onRequestRemoveCrew: { _ in },
                onRequestRemoveChild: { _, _ in },
                onSetCrewParent: { _, _ in },
                onStopDiscoveredSession: { _ in },
                onAdoptSession: { _, _ in },
                onRequestPromoteSession: { _ in },
                selection: Binding(get: { holder.selection }, set: { holder.selection = $0 }))
        }
    }

    private func mount(crews: [Crew], groups: [CrewGroup], holder: SelectionHolder,
                       onSetGroupFolded: @escaping (CrewGroup, Bool) -> Void) async -> NSWindow {
        let host = NSHostingView(rootView: Harness(
            holder: holder, crews: crews, groups: groups, onSetGroupFolded: onSetGroupFolded))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 216, height: 400))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        return window
    }

    private func crews() -> [Crew] {
        [Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B"),
         Crew(id: "c", displayName: "C"), Crew(id: "d", displayName: "D")]
    }

    /// Cmd-1…9's hidden buttons set `selection` to
    /// `SessionRef.owned(by: crew, name: crew.id)` for the Nth crew in
    /// `RailNesting.drawOrderCrews` — here, Cmd-3 landing on "d", the
    /// folded group's SECOND member, reordered next to "b" by the group.
    func testCmdNLandingOnAFoldedGroupMemberOpensIt() async throws {
        let group = CrewGroup(name: "Rentals", members: ["b", "d"], folded: true)
        let holder = SelectionHolder()
        var recorded: [(CrewGroup, Bool)] = []
        let window = await mount(crews: crews(), groups: [group], holder: holder) { group, folded in
            recorded.append((group, folded))
        }
        defer { window.orderOut(nil) }

        let drawOrder = RailNesting.drawOrderCrews(for: crews(), groups: [group])
        XCTAssertEqual(drawOrder.map(\.id), ["a", "b", "d", "c"], "precondition: d sits third in draw order")
        let crew = drawOrder[2]
        holder.selection = SessionRef.owned(by: crew, name: crew.id)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.0, group)
        XCTAssertEqual(recorded.first?.1, false, "a selection should OPEN the group, never close it")
    }

    /// A running START entry resolves to `.select(ref)`
    /// (`StartPicker.choose`), and `RailView`'s own popover handler sets
    /// `selection = ref` for exactly that case — here, an entry whose ref
    /// matches "b", a member of the folded group.
    func testAStartSelectionLandingOnAFoldedGroupMemberOpensIt() async throws {
        let group = CrewGroup(name: "Rentals", members: ["b", "d"], folded: true)
        let holder = SelectionHolder()
        var recorded: [(CrewGroup, Bool)] = []
        let window = await mount(crews: crews(), groups: [group], holder: holder) { group, folded in
            recorded.append((group, folded))
        }
        defer { window.orderOut(nil) }

        let entry = LaunchableSession(id: "b", displayName: "B")
        guard case .select(let ref) = StartPicker.choose(entry, isRunning: true) else {
            return XCTFail("a running entry should resolve to .select")
        }
        holder.selection = ref
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.0, group)
        XCTAssertEqual(recorded.first?.1, false)
    }

    /// Selecting a crew that is not in any folded group never calls back —
    /// the common case, so a folded-group check must not fire on every
    /// ordinary click.
    func testSelectingAnUngroupedCrewNeverTouchesGroups() async throws {
        let group = CrewGroup(name: "Rentals", members: ["b"], folded: true)
        let holder = SelectionHolder()
        var recorded: [(CrewGroup, Bool)] = []
        let window = await mount(crews: crews(), groups: [group], holder: holder) { group, folded in
            recorded.append((group, folded))
        }
        defer { window.orderOut(nil) }

        holder.selection = SessionRef(host: nil, name: "a")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(recorded.count, 0)
    }
}
