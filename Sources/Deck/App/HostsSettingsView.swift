import Foundation
import SwiftUI

/// Settings › Hosts — the named machines a crew can run on. Before this, a
/// host existed only if you could hand-edit `theme.json`'s `hosts` table;
/// that is unusable for anyone who is not the operator, the same reason Settings ›
/// Sessions exists at all. See `deck/specs/multiple-sessions-per-project`
/// §"Crews on different hosts".
///
/// MATCHES `SessionsSettingsView`'S IDIOM rather than inventing a second
/// one: a `List` with selection, a detail panel beneath for the selected
/// row, a sheet for adding. Its layout note applies unchanged — THE LIST IS
/// THE ONLY SCROLLER, so this is a plain stack rather than a `Form`, which
/// would bring its own scroll view and fight the list for the gesture.
struct HostsSettingsView: View {
    @EnvironmentObject private var store: ThemeStore
    @EnvironmentObject private var navigation: SettingsNavigation
    @EnvironmentObject private var railState: RailStateModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var selection: String?
    @State private var isAdding = false
    @State private var pendingRemoval: HostEntry?
    @State private var fieldError: String?
    @State private var testOutcomes: [String: HostTestOutcome] = [:]
    @State private var testingNames: Set<String> = []
    @State private var pairing: PairingRequest?

    /// The host the steward was just created on, waiting on the operator
    /// dismissing the post-creation note — nil the rest of the time. See
    /// `createStewardIfNeeded(after:)`. There is no decline path: the
    /// steward is part of the build (`StewardCrew.shouldCreate`), so this
    /// var exists only to tell the operator what was made, never to ask
    /// permission first.
    ///
    /// ONLY THIS VIEW'S OWN CREATE SETS IT. `ContentView`'s launch-time
    /// evaluation (`StewardCrew.launchTarget`) is the other place a steward
    /// can get created, and it deliberately does not — see that method's
    /// doc for why a modal over the main window on every fresh launch is
    /// worse than the row simply appearing on the rail unannounced.
    @State private var stewardJustCreated: HostEntry?

    /// A host just added that turned out to have no Builder server, waiting
    /// on the person's answer to the one-time install offer (CQ·158).
    /// Declining clears it; the host stays, and its row keeps the action.
    @State private var installOffer: HostEntry?

    /// The host whose install action was taken, presenting the install
    /// sheet — the single entry point CQ·160 replaces with a terminal pane
    /// that runs the installer over the host's ssh connection.
    @State private var installRequest: HostEntry?

    /// Hosts whose pre-install check is running, and the last not-ready
    /// reading per host (CQ·159). A `.ready` reading is never stored: it
    /// goes straight to `installRequest`.
    @State private var preInstallChecking: Set<String> = []
    @State private var preInstallReadings: [String: PreInstallReading] = [:]

    private var configuration: ThemeConfiguration { store.configuration }
    private var hosts: [HostEntry] { configuration.hosts }
    private var rail: [Crew] { configuration.railSessions ?? CrewCatalog.known }
    private var catalog: [LaunchableSession] { configuration.catalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            list

            controls
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

            if let entry = selection.flatMap({ name in hosts.first { $0.name == name } }) {
                Divider()
                detail(for: entry)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .frame(minWidth: 460, minHeight: 420, alignment: .topLeading)
        .onChange(of: selection) { _, _ in fieldError = nil }
        // The empty state's "Add a Host" button (`UnresolvedHostView`) sets
        // a fresh token and switches this tab in; this is the other half —
        // opening the sheet once that token is set, whether this tab was
        // already showing or `navigation` just switched it in.
        //
        // `initial: true` because on a cold launch the `Settings` scene
        // (and this view) does not exist yet when `openHostsWithAddSheet()`
        // runs — SwiftUI has to materialize the scene from `openSettings()`
        // first. By the time this view's body runs and this modifier
        // attaches, the token is already non-nil, so it is this modifier's
        // STARTING value rather than a transition it observes, and a
        // change-only `onChange` never fires. Every later click works
        // because SwiftUI keeps this view alive for the rest of the process
        // once Settings has opened once.
        //
        // Consuming the token back to nil once acted on keeps the request
        // one-shot — otherwise a later re-materialization of this view (or
        // any other `initial: true` read) would re-open the sheet unbidden.
        .onChange(of: navigation.addHostRequestToken, initial: true) { _, token in
            if token != nil {
                isAdding = true
                navigation.consumeAddHostRequest()
            }
        }
        // The no-runbook-link fallback for a logged-out alert
        // (`ContentView.openRunbookLink`, CQ·124) — same `initial: true`
        // reasoning as the Add Host sheet above: Settings may not exist yet
        // when the request is made.
        .onChange(of: navigation.selectHostRequest, initial: true) { _, hostName in
            if let hostName {
                selection = hostName
                navigation.consumeSelectHostRequest()
            }
        }
        .sheet(isPresented: $isAdding) {
            AddHostSheet(existingHosts: hosts) { entry in addHost(entry) }
        }
        .sheet(isPresented: Binding(
            get: { installRequest != nil },
            set: { if !$0 { installRequest = nil } })
        ) {
            if let entry = installRequest {
                installSheet(for: entry)
            }
        }
        .alert(
            "Install Builder\u{2019}s server on \u{201c}\(installOffer?.name ?? "")\u{201d}?",
            isPresented: Binding(
                get: { installOffer != nil },
                set: { if !$0 { installOffer = nil } })
        ) {
            Button("Not Now", role: .cancel) { installOffer = nil }
            Button("Install\u{2026}") {
                if let entry = installOffer { beginInstall(entry) }
                installOffer = nil
            }
        } message: {
            Text("\(installOffer?.name ?? "This host") has no Builder server, so it has no crews "
                 + "or steward yet. You can install it later from the host\u{2019}s row.")
        }
        .sheet(item: $pairing) { request in
            HostPairingSheet(target: request.target) { outcome in
                testOutcomes[request.hostName] = outcome
            }
        }
        .alert(
            pendingRemoval.map { "Remove \u{201c}\($0.name)\u{201d}?" } ?? "Remove host?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let entry = pendingRemoval {
                    store.removeHost(entry.name)
                    if selection == entry.name { selection = nil }
                }
                pendingRemoval = nil
            }
        } message: {
            Text(pendingRemoval.map(removalMessage) ?? "")
        }
        .alert(
            "Steward crew created on \u{201c}\(stewardJustCreated?.name ?? "")\u{201d}",
            isPresented: Binding(
                get: { stewardJustCreated != nil },
                set: { if !$0 { stewardJustCreated = nil } })
        ) {
            Button("OK", role: .cancel) { stewardJustCreated = nil }
        } message: {
            Text("A steward can help you work with everything else you set up here, "
                 + "explaining the system and coordinating work across your other crews. "
                 + "You'll find it on the rail now.")
        }
    }

    /// Adds a host, then asks it for its own crews root before creating a
    /// steward — see `deck/specs/running-deck-as-someone-else` and the
    /// `crews-root` verb in `platform/contracts/session-agent-api`.
    ///
    /// THE FETCH MUST LAND IN THE ENTRY BEFORE `createStewardIfNeeded` RUNS.
    /// `createSteward` builds the steward's directory from
    /// `HostResolution.crewsRoot` the moment it runs, so a race here
    /// reproduces the #103/#105 failure this whole change exists to
    /// prevent: the first crew on a fresh host, created under the wrong
    /// root. Adding the host immediately keeps the sheet responsive — only
    /// the steward creation waits on the round trip.
    ///
    /// A FAILED FETCH IS NOT AN ERROR TO SHOUT ABOUT. A host that is
    /// unreachable when it is added leaves `crewsRoot` unset; the operator
    /// can still type one, and steward creation still runs on schedule
    /// rather than blocking on the fetch succeeding.
    ///
    /// THE WRITE-BACK RE-READS THE ENTRY RATHER THAN REUSING THE CAPTURED
    /// ONE. The host row and its editable detail panel are on screen the
    /// instant `selection` is set, which is before the round trip has even
    /// started — so the natural recovery from a mistyped address is to fix
    /// it in that panel while the fetch is still in flight against the old
    /// one. Writing back the captured struct would carry every field with
    /// it and silently revert that fix; a rename in the same window would
    /// instead make `updateHost`'s own name guard miss, dropping the
    /// fetched root. Reading the live entry and setting only `crewsRoot` on
    /// top of it does neither: a concurrent edit survives, and the root
    /// still lands. An entry removed while the fetch ran writes nothing.
    private func addHost(_ entry: HostEntry) {
        store.addHost(entry)
        selection = entry.name
        let target = SSHTarget(user: entry.user, host: entry.address)
        Task {
            let fetched = await Task.detached {
                Result { try SessionAgent.crewsRoot(target: target) }
            }.value
            // A host with no Builder server gets the install offer instead
            // of a steward create that could only fail (CQ·158).
            if case .failure(let error) = fetched, BuilderServerTracker.isNotInstalled(error) {
                installOffer = entry
                return
            }
            let landed = HostsSettingsView.applyingFetchedRoot(
                try? fetched.get(), toHostNamed: entry.name, in: store) ?? entry
            createStewardIfNeeded(after: landed)
        }
    }

    /// Lands a fetched crews root on whatever the entry looks like NOW,
    /// returning the entry steward creation should proceed against — or
    /// nil when there is nothing to write, so the caller falls back to what
    /// it already had.
    ///
    /// VALIDATED BEFORE IT IS PERSISTED, unlike the global `crewsRoot` in
    /// `theme.json`, which is read back as typed.
    /// The hand-typed Add and Edit Host forms validate on write
    /// (`HostFormValidation.makeEntry`), and `ThemeConfiguration.parseHosts`
    /// validates every root read back from the file — a value arriving from
    /// a HOST rather than from the operator is the one that most deserves
    /// the same gate, since it is the only one nobody looked at. Nothing
    /// exploitable rides on this: `startArguments` validates again before
    /// the value reaches argv, and a malformed persisted root would be
    /// dropped by `parseHosts` on the next launch. It is here so a bad root
    /// never becomes a value the operator sees in Settings and believes.
    @MainActor
    static func applyingFetchedRoot(
        _ fetchedRoot: String?, toHostNamed name: String, in store: ThemeStore
    ) -> HostEntry? {
        guard let fetchedRoot,
              let validated = try? validateWorkingDirectory(fetchedRoot),
              var live = store.configuration.hosts.first(where: { $0.name == name })
        else { return nil }
        live.crewsRoot = validated
        store.updateHost(named: name, to: live)
        return live
    }

    /// Creates the steward crew when the condition is met — see
    /// `StewardCrew.shouldCreate` for the exact condition and why checking
    /// current state rather than a before/after delta makes this
    /// self-healing. TWO PATHS NOW EVALUATE IT: this one, on every host add,
    /// and `ContentView`'s launch-time evaluation, once per app start. A
    /// configured host with no crew yet (a prior create that threw, or a
    /// steward crew removed by hand) is picked back up by whichever of the
    /// two happens next — the very next launch if the operator does nothing
    /// else, or sooner if they add another host — rather than staying
    /// silenced by a decision the operator never made. Reads `rail` fresh
    /// rather than trusting a value captured earlier in the same `Task`.
    /// `store.stewardCreateInFlight` guards against both paths firing at
    /// once — see that property's doc.
    private func createStewardIfNeeded(after entry: HostEntry) {
        guard !store.stewardCreateInFlight,
              StewardCrew.shouldCreate(hostCount: hosts.count, crews: rail),
              !BuilderServerInstall.offersInstall(builderServerState(for: entry))
        else { return }
        createSteward(on: entry)
    }

    /// Runs `StewardCrew.create` off the main actor — an ssh round trip
    /// must not freeze Settings — then either adds the row and surfaces the
    /// post-creation note (success), or surfaces what happened through the
    /// same `store.saveError` channel every other launch failure in this
    /// app uses. A failure here must say what happened rather than leaving
    /// an empty rail with no explanation, so nothing here swallows the
    /// error silently, and nothing here writes any state that would block
    /// `createStewardIfNeeded` from trying again later beyond
    /// `stewardCreateInFlight` itself, which this always clears once the
    /// attempt resolves.
    private func createSteward(on entry: HostEntry) {
        store.stewardCreateInFlight = true
        let target = SSHTarget(user: entry.user, host: entry.address)
        let crewsRoot = HostResolution.crewsRoot(
            forHostName: entry.name, hosts: configuration.hosts,
            defaultHost: configuration.defaultHost, globalCrewsRoot: configuration.crewsRoot)
        let directory = StewardCrew.directory(crewsRoot: crewsRoot)
        let existingCrews = rail
        Task {
            let outcome = await StewardCrew.attemptCreate(
                target: target, directory: directory, existingCrews: existingCrews)
            store.stewardCreateInFlight = false
            switch outcome {
            case .success(let created):
                guard created else { return }
                store.addCrew(Crew(id: StewardCrew.id, displayName: StewardCrew.displayName,
                                    workingDirectory: directory, host: entry.name))
                stewardJustCreated = entry
            case .failure(let error) where BuilderServerTracker.isNotInstalled(error):
                installOffer = entry
            case .failure(let error):
                store.saveError = "Could not create the steward crew: \(error)"
            }
        }
    }

    /// The install action's gate (CQ·159): checks Claude Code's sign-in and,
    /// on a Mac, the desktop login before anything is offered to run. Only
    /// `.ready` opens the install; any other reading stays on the host's
    /// detail panel until the next attempt.
    private func beginInstall(_ entry: HostEntry) {
        guard !preInstallChecking.contains(entry.name) else { return }
        preInstallChecking.insert(entry.name)
        preInstallReadings[entry.name] = nil
        selection = entry.name
        let target = SSHTarget(user: entry.user, host: entry.address)
        Task {
            let reading = await Task.detached { PreInstallCheck.run(target: target) }.value
            preInstallChecking.remove(entry.name)
            if reading.allowsInstall {
                installRequest = entry
            } else {
                preInstallReadings[entry.name] = reading
            }
        }
    }

    /// The install sheet for `entry` (CQ·160). The argv is built here from
    /// the host's validated target and nothing else; a target that fails
    /// validation gets no terminal at all.
    @ViewBuilder
    private func installSheet(for entry: HostEntry) -> some View {
        let target = SSHTarget(user: entry.user, host: entry.address)
        if let arguments = try? BuilderServerInstall.arguments(target: target) {
            BuilderServerInstallSheet(
                hostName: entry.name,
                arguments: arguments,
                theme: configuration.theme(forSession: .localShell),
                appearance: configuration.appearance(for: .terminal, systemIsDark: colorScheme == .dark),
                typography: configuration.typography,
                verify: {
                    await railState.refresh()
                    return railState.builderServerState[target] == .installed
                },
                onInstalled: { createStewardIfNeeded(after: entry) })
        } else {
            Text("\(entry.name)\u{2019}s user or address is not usable for ssh.")
                .padding(20)
        }
    }

    private func builderServerState(for entry: HostEntry) -> BuilderServerState? {
        railState.builderServerState[SSHTarget(user: entry.user, host: entry.address)]
    }

    // MARK: - The list

    private var list: some View {
        List(selection: $selection) {
            Section {
                ForEach(hosts, id: \.name) { host in
                    row(host).tag(host.name)
                }
            } header: {
                Text("Hosts")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                    .padding(.bottom, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func row(_ host: HostEntry) -> some View {
        let isDefault = host.name == configuration.defaultHost
        return HStack(spacing: 8) {
            Button {
                store.setDefaultHost(isDefault ? nil : host.name)
            } label: {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(isDefault ? Color.accentColor : Color.secondary.opacity(0.45))
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDefault ? "The default host for a crew with no host of its own"
                             : "Make \(host.name) the default host")
            .accessibilityLabel("Default host")
            .accessibilityValue(isDefault ? "yes" : "no")

            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                Text("\(host.user)@\(host.address)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if BuilderServerInstall.offersInstall(builderServerState(for: host)) {
                Label("No Builder server", systemImage: "shippingbox")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if let outcome = testOutcomes[host.name] {
                testBadge(outcome)
            }
        }
    }

    @ViewBuilder
    private func testBadge(_ outcome: HostTestOutcome) -> some View {
        switch outcome {
        case .reachable(let machineName):
            Label(machineName, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .refused:
            Label("Refused", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .unreachable:
            Label("Unreachable", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    /// The +/− buttons, mirroring `SessionsSettingsView.controls` — a plus
    /// opens the Add sheet, a minus asks the remove confirm rather than
    /// removing outright, since a host's removal can leave crews naming
    /// nothing (see the confirm's message below).
    private var controls: some View {
        HStack(alignment: .top) {
            HStack(spacing: 0) {
                Button { isAdding = true } label: {
                    Image(systemName: "plus").frame(width: 20)
                }
                .help("Add a host")
                Divider().frame(height: 12)
                Button {
                    guard let selection, let entry = hosts.first(where: { $0.name == selection }) else { return }
                    pendingRemoval = entry
                } label: {
                    Image(systemName: "minus").frame(width: 20)
                }
                .disabled(selection == nil)
                .help("Remove the selected host")
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 12)

            Text("A host is an account on a machine. The star marks the default a "
                 + "crew with no host of its own resolves to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 280, alignment: .trailing)
        }
    }

    // MARK: - The selected host

    @ViewBuilder
    private func detail(for entry: HostEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.name)
                .font(.headline)

            LabeledContent("Name:") {
                CommittingField(
                    text: entry.name, prompt: HostsSettingsView.hostNamePlaceholder,
                    onCommit: { edit(entry, name: $0) })
                    .id("host-name-\(entry.name)")
            }
            LabeledContent("User:") {
                CommittingField(
                    text: entry.user, prompt: HostsSettingsView.hostUserPlaceholder(systemUser: NSUserName()),
                    onCommit: { edit(entry, user: $0) })
                    .id("host-user-\(entry.name)")
            }
            LabeledContent("Address:") {
                CommittingField(
                    text: entry.address, prompt: HostsSettingsView.hostAddressPlaceholder,
                    onCommit: { edit(entry, address: $0) })
                    .id("host-address-\(entry.name)")
            }
            LabeledContent("Crews root:") {
                CommittingField(
                    text: entry.crewsRoot ?? "", prompt: configuration.crewsRoot,
                    onCommit: { edit(entry, crewsRoot: $0) })
                    .id("host-crewsroot-\(entry.name)")
            }
            Text("Where this host's crews are created, if different from the global "
                 + "default in the General tab.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Runbook link:") {
                CommittingField(
                    text: entry.runbookLink ?? "", prompt: HostsSettingsView.hostRunbookLinkPlaceholder,
                    onCommit: { edit(entry, runbookLink: $0) })
                    .id("host-runbooklink-\(entry.name)")
            }
            Text("Opened from the \u{201c}logged out\u{201d} alert for this host \u{2014} "
                 + "an https:// URL, or a KB id Deck opens in its own pane. Left blank, the "
                 + "alert offers this host's row here instead.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Library transport:") {
                Text(LibraryTransportDisplay.label(
                    LibraryTransportSelector.shared.transport(
                        for: SSHTarget(user: entry.user, host: entry.address))))
                    .foregroundStyle(.secondary)
            }

            HostDesktopSessionStatusView(
                hostName: entry.name,
                knownState: railState.desktopSessionKnownState[SSHTarget(user: entry.user, host: entry.address)])

            if BuilderServerInstall.offersInstall(builderServerState(for: entry)) {
                HStack(spacing: 8) {
                    Label("\(entry.name) has no Builder server.", systemImage: "shippingbox")
                        .font(.caption).foregroundStyle(.orange)
                    Button(preInstallChecking.contains(entry.name) ? "Checking\u{2026}" : "Install Builder Server\u{2026}") {
                        beginInstall(entry)
                    }
                    .disabled(preInstallChecking.contains(entry.name))
                }
                if let reading = preInstallReadings[entry.name] {
                    Label(reading.explanation(hostName: entry.name), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let fieldError {
                Label(fieldError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(testingNames.contains(entry.name) ? "Testing\u{2026}" : "Test") {
                    runTest(entry)
                }
                .disabled(testingNames.contains(entry.name))

                if let outcome = testOutcomes[entry.name] {
                    testDetailText(outcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if case .refused(let text)? = testOutcomes[entry.name],
               HostPairing.offersPairing(testError: text) {
                Button("Pair this Mac\u{2026}") {
                    pairing = PairingRequest(
                        hostName: entry.name,
                        target: SSHTarget(user: entry.user, host: entry.address))
                }
            }

            Divider()
                .padding(.vertical, 4)
            RolloverPolicySection(host: entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func testDetailText(_ outcome: HostTestOutcome) -> some View {
        switch outcome {
        case .reachable(let machineName):
            Text(verbatim: "Answered as \u{201c}\(machineName)\u{201d}.")
        case .refused(let message):
            Text(verbatim: "The connection was refused: \(message)")
        case .unreachable(let message):
            Text(verbatim: "Unreachable: \(message)")
        }
    }

    /// Runs `HostProbe.test` off the main actor and records the outcome —
    /// see `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts": "the control that turns 'I typed an address' into 'it
    /// works'." Uses the host's OWN resolved target, not the rail's cache,
    /// so a host with no crew on it yet is still testable.
    private func runTest(_ host: HostEntry) {
        testingNames.insert(host.name)
        let target = SSHTarget(user: host.user, host: host.address)
        Task {
            let outcome = await HostProbe.test(target: target)
            testOutcomes[host.name] = outcome
            testingNames.remove(host.name)
        }
    }

    /// One field of the selected host was committed. Rebuilds a candidate
    /// entry from the other three fields plus the one that changed, and
    /// validates it through `HostFormValidation` — the same validators
    /// (`validateHostName`/`validateHostUser`/`validateHostAddress`) parsing
    /// and argv construction already use, per
    /// `deck/specs/multiple-sessions-per-project`: "The editor validates
    /// through THESE, not a second rule set." A failed edit is refused
    /// rather than written half-valid and silently dropped on the next
    /// `theme.json` load — `CommittingField`'s own revert-on-blur puts the
    /// field back to what is actually stored once this returns without
    /// updating the config.
    private func edit(
        _ entry: HostEntry, name: String? = nil, user: String? = nil,
        address: String? = nil, crewsRoot: String? = nil, runbookLink: String? = nil
    ) {
        do {
            let candidate = try HostFormValidation.makeEntry(
                name: name ?? entry.name,
                user: user ?? entry.user,
                address: address ?? entry.address,
                crewsRoot: crewsRoot ?? (entry.crewsRoot ?? ""),
                runbookLink: runbookLink ?? (entry.runbookLink ?? ""),
                existingHosts: hosts,
                excludingName: entry.name)
            fieldError = nil
            store.updateHost(named: entry.name, to: candidate)
            if candidate.name != entry.name { selection = candidate.name }
        } catch {
            fieldError = HostFormValidation.errorMessage(error)
        }
    }

    /// The remove confirm's message — see
    /// `deck/specs/multiple-sessions-per-project` §"Setting the default
    /// host": "The confirm should say how many crews will fall back and to
    /// where, the way `removeCrewMessage` names what is about to happen."
    private func removalMessage(for entry: HostEntry) -> String {
        let count = HostUsage.crewsNaming(entry.name, rail: rail, catalog: catalog)
        guard count > 0 else {
            return HostsSettingsView.removeHostMessage(crewCount: 0, fallbackLabel: "")
        }
        // What a crew still naming this host resolves to the instant it is
        // gone: the table and `defaultHost` exactly as `ThemeStore.removeHost`
        // will leave them — including its own reassignment when the removed
        // host WAS the default — so the confirm never quotes a fallback the
        // mutator will not actually produce.
        let hostsAfter = hosts.filter { $0.name != entry.name }
        let defaultAfter = configuration.defaultHost == entry.name ? nil : configuration.defaultHost
        let fallbackLabel = HostResolution.target(
            forHostName: entry.name, hosts: hostsAfter, defaultHost: defaultAfter
        ).map { HostDisplay.label(for: $0, hosts: hostsAfter, probed: { _ in nil }) }
        return HostsSettingsView.removeHostMessage(crewCount: count, fallbackLabel: fallbackLabel)
    }

    /// A PURE FUNCTION so the 0/1/2+ wording is pinned by a test rather than
    /// only read off the alert — the same discipline `ContentView.removeCrewMessage`
    /// follows.
    ///
    /// `fallbackLabel` is nil when nothing is left for an affected crew to
    /// resolve to — no other host, and no default — which removing this
    /// host can now produce, since a crew's fallback no longer bottoms out
    /// in a compiled-in box. See `deck/specs/running-deck-as-someone-else`.
    nonisolated static func removeHostMessage(crewCount: Int, fallbackLabel: String?) -> String {
        switch crewCount {
        case 0:
            return "This removes the host from the list."
        case 1:
            guard let fallbackLabel else {
                return "This removes the host from the list. 1 crew names it and will "
                    + "be left with no host to resolve to."
            }
            return "This removes the host from the list. 1 crew names it and will "
                + "fall back to \(fallbackLabel)."
        default:
            guard let fallbackLabel else {
                return "This removes the host from the list. \(crewCount) crews name it "
                    + "and will be left with no host to resolve to."
            }
            return "This removes the host from the list. \(crewCount) crews name it "
                + "and will fall back to \(fallbackLabel)."
        }
    }

    // MARK: - Ghost text

    /// The Name field's ghost text — a fictional example, so no real
    /// person's name ships in what a stranger sees on first launch.
    static let hostNamePlaceholder = "studio"

    /// The Address field's ghost text — RFC 5737 TEST-NET-1, reserved for
    /// documentation, so it can never be mistaken for a reachable host.
    static let hostAddressPlaceholder = "192.0.2.1"

    /// The Runbook link field's ghost text — a fictional KB id shaped like
    /// a real one, so no real runbook ships as example text in what a
    /// stranger sees on first launch.
    static let hostRunbookLinkPlaceholder = "team/runbooks/log-back-in"

    /// The User field's ghost text — this machine's own account, so no name
    /// is compiled into the binary: on the operator's laptop it shows their
    /// own account name, on anyone else's it shows theirs. Falls back to a
    /// fictional name when
    /// the system account name is unavailable, so the field is never blank.
    nonisolated static func hostUserPlaceholder(systemUser: String) -> String {
        systemUser.isEmpty ? "demouser" : systemUser
    }
}

/// The host a pairing sheet is for, from the Test button's failure. Keyed by
/// the host's name so the outcome lands on the right row.
private struct PairingRequest: Identifiable {
    let hostName: String
    let target: SSHTarget
    var id: String { hostName }
}

/// Adding a host offers a picker of machines already on the operator's
/// Tailnet — see `issue_01M0ECVNHX6XRT47EJJ8B5Z54T` — rather than asking up
/// front for an address nobody has been told how to find. Selecting a
/// machine fills Name and Address; the account name is the one thing
/// Tailscale cannot know, so it defaults to the local account
/// (`HostsSettingsView.hostUserPlaceholder`, #117) and stays editable.
///
/// MANUAL ENTRY IS THE FALLBACK, NOT THE DEFAULT — for a machine that is
/// reachable but not on the Tailnet, and for when `tailscale` is absent or
/// errors (`TailnetDiscovery.fetch` returns `.unavailable` for both). Either
/// way, whatever ends up in Name/User/Address still has to clear
/// `HostFormValidation.makeEntry`'s gates on submit — the picker only ever
/// pre-fills those same three fields, never bypasses their validation.
private struct AddHostSheet: View {
    let existingHosts: [HostEntry]
    let onAdd: (HostEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var user = HostsSettingsView.hostUserPlaceholder(systemUser: NSUserName())
    @State private var address = ""
    @State private var errorMessage: String?

    /// `nil` while `TailnetDiscovery.fetch` is still running.
    @State private var machines: [TailnetDiscovery.Machine]?
    @State private var manualEntry = false
    @State private var pairingTarget: SSHTarget?
    @State private var pairingNote: String?

    /// The address and user as the form now holds them, once both pass the
    /// same gates `HostFormValidation.makeEntry` applies. Pairing needs no
    /// name, so this is all it takes to open the sheet.
    private var validatedTarget: SSHTarget? {
        guard let user = try? validateHostUser(user.trimmingCharacters(in: .whitespaces)),
              let host = try? validateHostAddress(address.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return SSHTarget(user: user, host: host)
    }

    private var showsPicker: Bool {
        !manualEntry && !(machines ?? []).isEmpty
    }

    var body: some View {
        Form {
            if machines == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for machines on your Tailnet\u{2026}")
                        .foregroundStyle(.secondary)
                }
            } else if showsPicker {
                pickerFields
            } else {
                manualFields
                if !(machines ?? []).isEmpty {
                    Button("Pick from your Tailnet instead") { manualEntry = false }
                        .buttonStyle(.link)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            if let pairingNote {
                Text(pairingNote).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Pair this Mac\u{2026}") { pairingTarget = validatedTarget }
                    .disabled(validatedTarget == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(.vertical, 8)
        .sheet(isPresented: Binding(
            get: { pairingTarget != nil },
            set: { if !$0 { pairingTarget = nil } })
        ) {
            if let pairingTarget {
                HostPairingSheet(target: pairingTarget) { outcome in
                    pairingNote = HostPairing.note(afterTest: outcome)
                }
            }
        }
        .task {
            switch await TailnetDiscovery.fetch() {
            case .machines(let found):
                machines = found
            case .unavailable:
                machines = []
                manualEntry = true
            }
        }
    }

    @ViewBuilder
    private var pickerFields: some View {
        Section("Machines on your Tailnet") {
            ForEach(machines ?? []) { machine in
                Button {
                    name = machine.hostName
                    address = machine.address
                } label: {
                    machineRow(machine)
                }
                .buttonStyle(.plain)
            }
        }
        // Editable rather than a label — a picked machine's hostname can
        // collide with a host already in the list (`HostFormValidation`
        // refuses a duplicate name), and without a field to fix it from
        // here, the only way out was switching to manual entry.
        if !name.isEmpty {
            TextField("Name:", text: $name, prompt: Text(HostsSettingsView.hostNamePlaceholder))
        }
        TextField("User:", text: $user,
                   prompt: Text(HostsSettingsView.hostUserPlaceholder(systemUser: NSUserName())))
        Text("The account Deck logs in as. Its machine and address are filled in above.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Enter an address manually instead") { manualEntry = true }
            .buttonStyle(.link)
    }

    /// One row of the picker. Selectable whether the machine is online or
    /// not — a box being asleep is not a reason to refuse to configure it.
    private func machineRow(_ machine: TailnetDiscovery.Machine) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(machine.isOnline ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.hostName)
                Text(machine.address)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !machine.isOnline {
                Text("Offline").font(.caption2).foregroundStyle(.secondary)
            }
            if name == machine.hostName && address == machine.address {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var manualFields: some View {
        TextField("Name:", text: $name, prompt: Text(HostsSettingsView.hostNamePlaceholder))
        TextField("User:", text: $user,
                   prompt: Text(HostsSettingsView.hostUserPlaceholder(systemUser: NSUserName())))
        TextField("Address:", text: $address, prompt: Text(HostsSettingsView.hostAddressPlaceholder))
            .font(.system(size: 11.5, design: .monospaced))
        Text("The account and machine this host connects to.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func submit() {
        do {
            let entry = try HostFormValidation.makeEntry(
                name: name, user: user, address: address, crewsRoot: "",
                existingHosts: existingHosts)
            onAdd(entry)
            dismiss()
        } catch {
            errorMessage = HostFormValidation.errorMessage(error)
        }
    }
}
