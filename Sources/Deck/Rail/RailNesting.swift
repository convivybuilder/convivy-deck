import Foundation

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
}
