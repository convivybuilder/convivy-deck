import Foundation

/// An operator-defined fold on the rail (E24), stored beside `rail` in
/// `theme.json` — see `ThemeConfiguration.groups`. A member names a
/// TOP-LEVEL crew by its `ref` — the same `host|session` key the `sessions`
/// colour map already uses — never a nested crew or a pinned child, which
/// travel with their top-level crew rather than joining a group on their
/// own.
struct CrewGroup: Equatable {
    var name: String
    var members: [SessionRef]
    var folded: Bool
}

/// Where a crew draws in the rail's tree — the one-level rule from
/// `deck/specs/multiple-sessions-per-project` §"Nested rendering" and
/// §"Why a crew is a directory". PURE over `[Crew]`, so every case the spec
/// calls out (a flat list, a dangling parent, a self-parent, a two-level
/// chain, a cycle) is a unit test rather than a view.
enum RailNesting {
    /// A drawn row: a crew and how many levels it nests, 0 for every
    /// top-level row and 1 for a crew nested under one — depth never goes
    /// past 1, since nothing here recurses past a single lookup.
    struct Row: Identifiable, Equatable {
        let crew: Crew
        let depth: Int
        var id: String { crew.ref.stringForm }
    }

    /// The crew `crew` draws nested under, or nil when it draws top-level.
    ///
    /// A crew nests only when its `parent` names another crew ON ITS OWN HOST
    /// that is ITSELF top-level — has no `parent` of its own. That single
    /// check is what enforces "one level only": a crew whose parent itself
    /// names a parent fails it (so does every crew downstream of a cycle,
    /// since nothing in a cycle has a nil `parent` to bottom out on), a
    /// dangling parent fails it because there is no crew to find, and a crew
    /// naming itself is refused outright before either lookup runs.
    ///
    /// THE HOST MATCH IS WHAT KEEPS A PARENT LINK LOCAL TO ONE MACHINE. A
    /// crew is a directory and a directory is on one host, so a nested crew
    /// and its parent are on the same host; a crew naming a parent that
    /// exists only on another host draws top-level, exactly as a dangling
    /// parent does. Without the match, pinning macmini's crew under a parent
    /// would nest it under macstudio's same-named crew instead.
    ///
    /// Hosts compare RESOLVED (`CrewMerge.crewHostKey`), so a crew still
    /// naming a host removed from Settings, which runs on the default host,
    /// nests under a parent there. With `hosts` empty the names compare as
    /// written.
    static func nestingParent(
        of crew: Crew, in crews: [Crew], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> Crew? {
        let host = CrewMerge.crewHostKey(for: crew, hosts: hosts, defaultHost: defaultHost)
        guard let parentId = crew.parent, parentId != crew.id,
              let parent = crews.first(where: {
                  $0.id == parentId && CrewMerge.crewHostKey(for: $0, hosts: hosts, defaultHost: defaultHost) == host
              }),
              parent.parent == nil
        else { return nil }
        return parent
    }

    static func isTopLevel(
        _ crew: Crew, in crews: [Crew], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> Bool {
        nestingParent(of: crew, in: crews, hosts: hosts, defaultHost: defaultHost) == nil
    }

    /// How far the rail indents a crew's row: an open group's member by
    /// `RailGroupHeadingRow.memberIndent`, and a nested crew one child
    /// indent beyond its parent. Sessions settings lists the pinned block
    /// with the same offsets, so the two read as one tree.
    static func railIndent(
        of crew: Crew, in crews: [Crew], groups: [CrewGroup],
        hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> CGFloat {
        let parent = nestingParent(of: crew, in: crews, hosts: hosts, defaultHost: defaultHost)
        let inGroup = group(containing: (parent ?? crew).ref, in: groups) != nil
        return (inGroup ? RailGroupHeadingRow.memberIndent : 0) + (parent == nil ? 0 : RailChildRow.indent)
    }

    /// Every top-level row, in `crews`' own order — what Cmd-1…9 counts
    /// against (design §"The rail": "Cmd-1…9 stays mapped to the first nine
    /// top-level rows") and what the rail's outer list iterates.
    static func topLevelCrews(
        _ crews: [Crew], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [Crew] {
        crews.filter { isTopLevel($0, in: crews, hosts: hosts, defaultHost: defaultHost) }
    }

    /// A top-level crew's nested children, in `crews`' own order — the same
    /// "config order" convention a crew's pinned sessions already draw in.
    static func nestedCrews(
        of crew: Crew, in crews: [Crew], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [Crew] {
        crews.filter {
            nestingParent(of: $0, in: crews, hosts: hosts, defaultHost: defaultHost)?.ref == crew.ref
        }
    }

    /// The full draw order — each top-level crew immediately followed by
    /// its nested children — with each row's depth. This is what a test
    /// pins directly; `RailView` draws the same tree but interleaves a
    /// crew's own sessions between it and its nested children, so it calls
    /// `topLevelCrews`/`nestedCrews` rather than this.
    static func flatten(_ crews: [Crew]) -> [Row] {
        topLevelCrews(crews).flatMap { top in
            [Row(crew: top, depth: 0)]
                + nestedCrews(of: top, in: crews).map { Row(crew: $0, depth: 1) }
        }
    }

    /// "Nest under ▸"'s menu — design §"Setting a parent is a UI act":
    /// every top-level crew except this one and whichever it is already
    /// nested under. Only a crew with no `parent` of its own is offered,
    /// because nesting under anything else could never satisfy
    /// `nestingParent`'s own rule the moment it was written — offering it
    /// would draw a menu item that immediately nests nowhere.
    ///
    /// ONLY CREWS ON THIS CREW'S OWN HOST are offered, for the same reason
    /// `nestingParent` matches on host: a crew on another host could never
    /// satisfy that rule either, so offering it would draw a menu item whose
    /// click did nothing visible.
    static func eligibleParents(
        for crew: Crew, in crews: [Crew], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [Crew] {
        let host = CrewMerge.crewHostKey(for: crew, hosts: hosts, defaultHost: defaultHost)
        return crews.filter {
            CrewMerge.crewHostKey(for: $0, hosts: hosts, defaultHost: defaultHost) == host
                && $0.parent == nil && $0.id != crew.id && $0.id != crew.parent
        }
    }

    // MARK: - Groups (E24)

    /// One row of the rail's TOP-LEVEL draw order: an ungrouped crew on its
    /// own, or a group section carrying its members. `RailView` draws a
    /// `.crew` exactly as it always has and a `.group` as a folding heading
    /// over its members — each member's own nested crews and pinned
    /// sessions are unaffected, since this type only buckets top-level rows.
    struct DrawItem: Identifiable {
        enum Kind {
            case crew(Crew)
            case group(CrewGroup, members: [Crew])
        }
        let kind: Kind
        var id: String {
            switch kind {
            case .crew(let crew): return "crew:\(crew.ref.stringForm)"
            case .group(let group, _): return "group:\(group.name)"
            }
        }
    }

    /// Which group (by index into `groups`) each member crew belongs to —
    /// first group wins for a crew named in two, the one membership rule
    /// `drawItems` and `foldedGroup` both read from rather than each
    /// re-deriving it.
    private static func groupMembership(_ groups: [CrewGroup]) -> [SessionRef: Int] {
        var membership: [SessionRef: Int] = [:]
        for (index, group) in groups.enumerated() {
            for member in group.members where membership[member] == nil {
                membership[member] = index
            }
        }
        return membership
    }

    /// The rail's top-level draw order with `groups` applied — ungrouped
    /// crews drawn exactly where they sit today, and each group drawn once,
    /// at its first member's rail position, holding every one of its
    /// members still on the rail, in rail order. A member naming a crew not
    /// on the rail is ignored, and a group none of whose members are on the
    /// rail draws nothing at all, since nothing in `crews` ever triggers it.
    static func drawItems(
        for crews: [Crew], groups: [CrewGroup], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [DrawItem] {
        let topLevel = topLevelCrews(crews, hosts: hosts, defaultHost: defaultHost)
        let membership = groupMembership(groups)
        var drawnGroupIndices: Set<Int> = []
        var items: [DrawItem] = []
        for crew in topLevel {
            guard let groupIndex = membership[crew.ref] else {
                items.append(DrawItem(kind: .crew(crew)))
                continue
            }
            guard !drawnGroupIndices.contains(groupIndex) else { continue }
            drawnGroupIndices.insert(groupIndex)
            let members = topLevel.filter { membership[$0.ref] == groupIndex }
            items.append(DrawItem(kind: .group(groups[groupIndex], members: members)))
        }
        return items
    }

    /// `drawItems` flattened to its crews alone, in draw order — what
    /// Cmd-1…9 counts against (design §"The rail": "Cmd-1…9 counts crews in
    /// draw order, folded or not"), so a group's members claim the
    /// shortcuts their drawn position would give them even while the group
    /// itself is folded.
    static func drawOrderCrews(
        for crews: [Crew], groups: [CrewGroup], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [Crew] {
        drawItems(for: crews, groups: groups, hosts: hosts, defaultHost: defaultHost).flatMap { item in
            switch item.kind {
            case .crew(let crew): return [crew]
            case .group(_, let members): return members
            }
        }
    }

    /// The folded group `ref` belongs to, or nil when it belongs to none or
    /// its group is already open — what selecting a session checks before
    /// opening the group that is hiding it (design §"Selection"). Reads the
    /// same first-group-wins membership `drawItems` does, so the group this
    /// opens is always the one `ref` actually draws under.
    static func foldedGroup(containing ref: SessionRef, in groups: [CrewGroup]) -> CrewGroup? {
        guard let index = groupMembership(groups)[ref], groups[index].folded else { return nil }
        return groups[index]
    }

    /// The group `ref` belongs to regardless of fold state, or nil — the
    /// same first-group-wins membership `foldedGroup` reads, used to decide
    /// what a crew's own "Move to Group"/"Remove from Group" menu offers
    /// (CQ·184): the menu lists every OTHER group and shows "Remove from
    /// Group" only when this is non-nil.
    static func group(containing ref: SessionRef, in groups: [CrewGroup]) -> CrewGroup? {
        guard let index = groupMembership(groups)[ref] else { return nil }
        return groups[index]
    }

    /// `groups` in the order they actually draw on the rail — each group's
    /// position in the sequence `drawItems` would emit, which is where
    /// Settings › Sessions lists them for CQ·184's up/down reorder. A group
    /// none of whose members are on the rail draws nowhere (`drawItems`'
    /// own doc), so it is appended after the drawn ones in `groups`' own
    /// array order rather than dropped from the listing outright — Settings
    /// still has to offer renaming or deleting it.
    static func orderedGroups(
        for crews: [Crew], groups: [CrewGroup], hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [CrewGroup] {
        let drawn = drawItems(for: crews, groups: groups, hosts: hosts, defaultHost: defaultHost)
            .compactMap { item -> CrewGroup? in
                if case .group(let group, _) = item.kind { return group }
                return nil
            }
        let drawnNames = Set(drawn.map(\.name))
        return drawn + groups.filter { !drawnNames.contains($0.name) }
    }

    /// Rewrites `crews`' top-level order so `group` swaps places with
    /// whichever top-level draw item sits immediately before it (`up:
    /// true`) or after it (`up: false`) — `ThemeStore.moveGroup`'s up/down
    /// reorder (CQ·184 bullet 2: "a reorder rewrites the `rail` array: the
    /// moved group's members become contiguous at the new position, in
    /// their existing relative order"). Returns nil, for the caller to treat
    /// as a no-op, when `group` is not currently drawn at all or has no
    /// neighbor in the requested direction.
    ///
    /// ONLY TOP-LEVEL SLOTS ARE TOUCHED. A nested crew's position in `crews`
    /// never affects where it draws — that is derived from its `parent`
    /// field alone (`nestingParent`), never from array order — so leaving
    /// every nested crew at its own original index changes nothing about
    /// what the rail shows while still satisfying "everything else in each
    /// rail row stays as it was."
    static func movingGroup(
        _ group: CrewGroup, up: Bool, in crews: [Crew], groups: [CrewGroup],
        hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [Crew]? {
        let items = drawItems(for: crews, groups: groups, hosts: hosts, defaultHost: defaultHost)
        guard let index = items.firstIndex(where: {
            if case .group(let drawnGroup, _) = $0.kind { return drawnGroup.name == group.name }
            return false
        }) else { return nil }
        let targetIndex = up ? index - 1 : index + 1
        guard items.indices.contains(targetIndex) else { return nil }

        var reordered = items
        reordered.swapAt(index, targetIndex)
        let newTopLevelOrder: [Crew] = reordered.flatMap { item in
            switch item.kind {
            case .crew(let crew): return [crew]
            case .group(_, let members): return members
            }
        }

        var newOrder = newTopLevelOrder.makeIterator()
        return crews.map { crew in
            isTopLevel(crew, in: crews, hosts: hosts, defaultHost: defaultHost)
                ? (newOrder.next() ?? crew)
                : crew
        }
    }
}
