import Foundation

/// One row from `session-agent crews` — a crew spec the steward's `new-crew`
/// (or `new-subcrew`) skill wrote to `~/.config/convivy/deck/crews.d/<id>.json`
/// on the host, describing a crew Deck did not necessarily configure itself.
/// See `platform/contracts/session-agent-api`'s `crews` section for the
/// producer side of this shape.
///
/// EPHEMERAL, like `DiscoveredSession`: never written to `theme.json` by this
/// decoder. `CrewMerge` folds it into a `Crew` for drawing; the spec file on
/// the host stays the one place this data is durable.
struct ServedCrew: Identifiable, Equatable {
    /// A served crew's identity: the actual resolved target it was found on,
    /// plus its own id — see `host` below, and `DiscoveredSession.ID`, which
    /// this mirrors for the same reason.
    struct ID: Hashable {
        var host: SSHTarget
        var crewId: String
    }

    /// One child session from a crew spec's `sessions` array.
    struct Child: Equatable {
        let name: String
        let displayName: String?
        let sessionId: String?
    }

    /// The crew's tmux session name — the spec file's own name, per the
    /// contract ("the file's own name, and the only field a row cannot be
    /// served without"). Named `crewId` rather than `id` because `id` is
    /// `Identifiable`'s host-qualified form below.
    let crewId: String
    /// The actual `SSHTarget` this row was found on — set at decode time by
    /// `RailStateModel`'s per-host poll task, from the target that task
    /// polled `session-agent crews` against. NEVER derived from the spec's
    /// own `host` string (see `specHost` below) — the same split
    /// `DiscoveredSession.host` draws against a discovered row's `path`.
    let host: SSHTarget
    let displayName: String?
    /// Gated through `validateWorkingDirectory` at decode time, the same gate
    /// every other working directory passes before it can reach an ssh
    /// command line. A value that fails degrades to `nil` here — the field
    /// costs itself, not the row — the same discipline
    /// `ThemeConfiguration.parseRail` applies to a hand-edited config's own
    /// `workdir`.
    let workingDirectory: String?
    /// tmux's `#{session_id}`, recorded at creation — the field that
    /// survives a rename, which a name does not.
    let sessionId: String?
    /// The wire's own `host` field: the host name the spec says it was
    /// written on (`"mini"`), a fact ABOUT the crew rather than the actual
    /// target this row was fetched from. Distinct from `host` above on
    /// purpose — see that field's doc.
    let specHost: String?
    let project: String?
    let bead: String?
    /// The GitHub `owner/repo` this crew's Pull Requests panel follows, if
    /// the spec names exactly one — see `Crew.repo`. UNDOCUMENTED IN
    /// `platform/contracts/session-agent-api` as of this field's
    /// introduction, the same undocumented-contract note `shape` and
    /// `documents` below carry.
    ///
    /// KEPT ALONGSIDE `repos` BELOW rather than folded into it, so a spec
    /// written before a crew could name several still decodes exactly as it
    /// always has — see `resolvedRepos`, which is what a reader actually
    /// wants.
    let repo: String?
    /// The spec's own plural `repos` key, if it has one — `nil` when the key
    /// is absent (as every spec written before
    /// issue_01M2P5JHM1G8XCMKM4HEHVJB2P is) or decodes to no usable entries.
    /// `resolvedRepos` falls back to the singular `repo` whenever this list
    /// is empty, whatever the reason it ended up that way — see that
    /// property's doc. UNDOCUMENTED IN `platform/contracts/session-agent-api`
    /// as of this field's introduction, the same note `repo` carries.
    let repos: [String]?
    let sessions: [Child]
    /// Which of `project`/`bead` the host filled in because the spec left
    /// them unset — see the contract's `derived` field.
    let derived: [String]
    /// The crew's rest-state shape, if the spec names one — see `Crew.shape`.
    /// UNDOCUMENTED IN `platform/contracts/session-agent-api` as of this
    /// field's introduction (the steward-board proposal, 2026-09-09, phase A):
    /// the `crews` envelope's contract doc does not yet describe `shape` or
    /// `documents` below. Named explicitly rather than left to drift — phase D
    /// of that proposal is the steward's own `new-crew` work that will write
    /// both fields and is where the contract doc catches up.
    let shape: String?
    /// The crew's working-documents list, if the spec names one — see
    /// `Crew.documents`. Same undocumented-contract note as `shape`. Each
    /// entry is gated through `validateDocumentEntry` at decode time, the
    /// same "field costs itself" discipline `workingDirectory` above
    /// applies via `validateWorkingDirectory` — see that function's doc for
    /// why it is a sanity check, not the containment boundary a document is
    /// actually held to when opened.
    let documents: [String]

    var id: ID { ID(host: host, crewId: crewId) }

    init(crewId: String, host: SSHTarget, displayName: String? = nil,
         workingDirectory: String? = nil, sessionId: String? = nil,
         specHost: String? = nil, project: String? = nil, bead: String? = nil, repo: String? = nil,
         repos: [String]? = nil, sessions: [Child] = [], derived: [String] = [],
         shape: String? = nil, documents: [String] = []) {
        self.crewId = crewId
        self.host = host
        self.displayName = displayName
        self.workingDirectory = workingDirectory
        self.sessionId = sessionId
        self.specHost = specHost
        self.project = project
        self.bead = bead
        self.repo = repo
        self.repos = repos
        self.sessions = sessions
        self.derived = derived
        self.shape = shape
        self.documents = documents
    }

    /// The list a reader actually wants: the plural `repos` key when it
    /// validates to at least one entry, otherwise the singular `repo` key
    /// wrapped as a one-element list, otherwise empty. `repos` falls back to
    /// the singular rather than winning outright whenever it validates
    /// empty — whether the key was never written, was written as `[]`,
    /// decoded with every entry unusable at the JSON-type level
    /// (`compactMap`'s `[Any] -> [String]` cast, same as `documents`), or
    /// decoded to strings that are simply not valid `owner/repo` identities
    /// — so a producer that always emits the plural key, even empty or
    /// junk, cannot shadow a perfectly good singular `repo` underneath it.
    /// This is the "this crew's repos" accessor
    /// issue_01M2P5JHM1G8XCMKM4HEHVJB2P asks for on the served-spec side —
    /// `Crew.repos` is its counterpart once `CrewMerge` has folded a spec
    /// into a configured row.
    ///
    /// **Each entry runs through `LibraryClient.validateRepoIdentity`,
    /// singular `repo` included** — matching `ThemeConfiguration.parseRepos`'s
    /// own per-entry gate on the hand-edited-file side, and closing a gap
    /// `repo` alone has carried since `#238` introduced it: a served
    /// `"repo": "not a repo"` decoded and was accepted here even though the
    /// identical string typed into Settings was refused by the same
    /// validator. That gap was inert while only `repos.first` was ever
    /// read; `CockpitResolution.prLadderRepos` is what starts actually
    /// querying every entry this property returns, so an unvalidated one
    /// is now a repo Deck would otherwise fetch pull requests for.
    var resolvedRepos: [String] {
        func valid(_ raw: String) -> String? {
            LibraryClient.validateRepoIdentity(raw).map { "\($0.owner)/\($0.repoName)" }
        }
        if let repos, !repos.isEmpty {
            let validated = repos.compactMap(valid)
            if !validated.isEmpty { return validated }
        }
        return repo.flatMap(valid).map { [$0] } ?? []
    }

    /// Decodes the `{"crews": [...]}` envelope.
    ///
    /// A TOTAL FUNCTION OF THE BYTES, never throwing — the same discipline
    /// `DiscoveredSession.decode` follows, for the same reason: this runs
    /// inside the rail's poll loop, where an uncaught error is not an
    /// option. A payload that is not a JSON object, or has no `crews` array,
    /// decodes to `[]`.
    ///
    /// A ROW MISSING `id` COSTS ONLY ITSELF. Per the contract, `id` is "the
    /// only field a row cannot be served without" — everything else
    /// degrades independently, the same per-field discipline
    /// `DiscoveredSession` follows for `path`/`windows`/`attached`. Every
    /// other field reads as `nil` (or an empty array, for `sessions`/
    /// `derived`) when it is absent, the wrong type, or — for
    /// `workingDirectory` — fails the same validation an ssh command line
    /// would refuse it for.
    static func decode(_ data: Data, host: SSHTarget) -> [ServedCrew] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawCrews = root["crews"] as? [Any] else {
            return []
        }
        var out: [ServedCrew] = []
        out.reserveCapacity(rawCrews.count)
        for item in rawCrews {
            guard let dict = item as? [String: Any],
                  let crewId = dict["id"] as? String, !crewId.isEmpty else { continue }
            out.append(ServedCrew(
                crewId: crewId,
                host: host,
                displayName: dict["displayName"] as? String,
                workingDirectory: (dict["workingDirectory"] as? String)
                    .flatMap { try? validateWorkingDirectory($0) },
                sessionId: dict["sessionId"] as? String,
                specHost: dict["host"] as? String,
                project: dict["project"] as? String,
                bead: dict["bead"] as? String,
                repo: dict["repo"] as? String,
                repos: (dict["repos"] as? [Any])?.compactMap { $0 as? String },
                sessions: decodeChildren(dict["sessions"]),
                derived: (dict["derived"] as? [Any])?.compactMap { $0 as? String } ?? [],
                shape: dict["shape"] as? String,
                documents: (dict["documents"] as? [Any])?.compactMap { $0 as? String }
                    .compactMap(validateDocumentEntry) ?? []))
        }
        return out
    }

    /// A `documents` entry costs only itself, the same per-field discipline
    /// `workingDirectory` above applies via `validateWorkingDirectory`. This
    /// is a decode-time SANITY check, not the containment boundary — it
    /// cannot know which hosts are configured, so it rejects only shapes
    /// that are never legitimate anywhere (empty, oversized, a `..`
    /// traversal component, or a control character that would corrupt a log
    /// line or a viewer). Holding an entry to the actual allowed roots
    /// happens later, when it is opened — see
    /// `ContentView.openRestStateDocument`, which passes it through
    /// `DeckOpenRef.validatePath` — and this check is not a substitute for
    /// that one.
    private static func validateDocumentEntry(_ entry: String) -> String? {
        guard !entry.isEmpty, entry.count <= 1024, !entry.contains(".."),
              entry.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.inverted.contains)
        else { return nil }
        return entry
    }

    /// A child costs only itself, the same rule the crew row above follows —
    /// `name` is the one field a child cannot be served without.
    private static func decodeChildren(_ raw: Any?) -> [Child] {
        guard let rawSessions = raw as? [Any] else { return [] }
        return rawSessions.compactMap { item -> Child? in
            guard let dict = item as? [String: Any],
                  let name = dict["name"] as? String, !name.isEmpty else { return nil }
            return Child(name: name,
                        displayName: dict["displayName"] as? String,
                        sessionId: dict["sessionId"] as? String)
        }
    }
}
