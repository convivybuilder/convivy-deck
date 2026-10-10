import SwiftUI

/// The session pane: a rendered conversation with a native frame that drives it.
///
/// THIS REPLACES THE TERMINAL, it does not accompany it. The tmux terminal is
/// where a decision you made and the thousandth `cat` render at the same weight;
/// this is the surface you live in, and the terminal becomes the drift-proof
/// fallback that is always underneath and almost never on screen.
///
/// It lands only because it is interactive. A read-only pane does strictly less
/// than the terminal it would replace, which is why the renderer sat unused in
/// Deck until the input verbs existed.
///
/// THE FRAME IS THE INTERFACE. Everything you act through here is native — the
/// message box, the state, the answer buttons, the interrupt. The web view holds
/// only the conversation. That is the boundary rule, and it is also what lets
/// the web view stay JavaScript-free with no bridge for page content to reach.
@MainActor
struct SessionPaneView: View {
    let session: String
    /// The crew or child's human name, for the `.who` mark at the head of
    /// `PaneStatusBar` — the same reading `ContentView.displayName(for:)`
    /// resolves for every other surface, threaded in rather than rederived so
    /// this pane cannot disagree with the rail row that opened it.
    let displayName: String
    let appearance: Appearance
    /// Passed in rather than read from the environment, matching `appearance`:
    /// the shell resolves configuration once and hands each surface what it
    /// needs, so a pane cannot disagree with the window it sits in.
    let sendKey: SendKeyPreference
    /// The canvas the shell painted for this session — the terminal's own
    /// background, lifted. Threaded like `appearance` and for the same reason:
    /// the shell resolves the theme once and tells every surface, so a pane can
    /// never disagree with the rail row that opened it.
    let canvas: String?
    /// The session's accent, from the same resolution the rail row draws with,
    /// so the dot in the live bar and the dot on the row that opened this pane
    /// are provably the same colour. Nil when the shell has no theme for it,
    /// which falls the live bar back to a neutral.
    var accent: RGB?
    /// Whether the shell has a start in flight for this session. The pane polls
    /// the moment it is selected, which on a launch is before the tmux session
    /// exists, so it would otherwise show "cannot reach the session" — the
    /// offline message — during a perfectly normal start.
    let isLaunching: Bool
    /// The pane's text scale, from the same preference Cmd-+/- moves.
    let textScale: Double
    let sessionLineHeight: Double
    let composerTypography: ComposerTypography
    /// Surfaces the raw terminal. The pane calls this when it cannot honestly
    /// drive the session — an unknown state, a gate it cannot render — rather
    /// than showing something plausible and wrong.
    var onFallBackToTerminal: () -> Void
    /// Stops the session — asks the agent to exit and closes it. The pane only
    /// asks; the shell owns the confirmation, because stopping is destructive and
    /// the pane is not where a "are you sure" belongs.
    var onStop: () -> Void = {}
    /// Fires on every transition of whether `model.state` carries a gate —
    /// both directions, opening and closing. The shell wires this to
    /// `RailStateModel.applyPushedGate` so the rail's own ⌘1-9 suppression
    /// (`RailView.suppressesNumberShortcuts`) learns about a gate on the
    /// selected session the moment this pane's follower does, rather than
    /// waiting out the rail's own four-second poll — see
    /// `RailStateModel.pushedGate`'s doc for why the two readings can
    /// otherwise disagree with what is on screen. Defaults to a no-op so
    /// every other call site (tests included) is unaffected.
    var onGateChange: (Bool) -> Void = { _ in }
    /// Called when a `deck-open:` link is clicked in the conversation. The origin
    /// has already been validated; the shell opens the viewer for it.
    var onDeckOpen: ((DeckOpenRef.Origin) -> Void)?
    /// Every configured host, threaded to `ConversationWebView` so it validates
    /// a `deck-open:` `path` ref against the roots they derive — see
    /// `DeckOpenRef.allowedPathRoots(hosts:)`.
    let hosts: [HostEntry]
    /// The co's own recording of what it is working on right now — read from
    /// the rail's brief poll (`RailStateModel.states`), not this pane's own,
    /// so a second poll is not spent on one line of text. The same value
    /// `WaypointRibbon` takes for its pulse. `PaneStatusBar` draws its text
    /// and age unless something more urgent pre-empts the slot — see that
    /// type's doc.
    var workingOn: SessionState.WorkingOn?
    /// The find bar's shared presentation state — one instance, owned by
    /// `ContentView`, that also drives the main pane's `TerminalFindBar` when
    /// the surface switches. Passed in rather than created here because
    /// `ConversationFindBar` (built from `scrollState` below) has to be the
    /// SAME bar the terminal side draws, not a second one that happens to
    /// look like it.
    @ObservedObject var findBarState: FindBarState
    /// The cockpit's own `PRLadderModel` — reused for the PR chip whenever
    /// this session's PR belongs to the same repo the cockpit is already
    /// showing, so the two surfaces read one fetch rather than two. Owned by
    /// `ContentView`, on the same footing `findBarState` is threaded on.
    @ObservedObject var sharedPRLadder: PRLadderModel
    /// `ContentView`'s fallback `PRLadderModel`, kept fetching whenever this
    /// session's PR belongs to a DIFFERENT repo than `sharedPRLadder`
    /// currently covers — see `ContentView.sessionReviewChipFetchTarget`'s
    /// doc for why one shared fallback instance, not one per pane, is
    /// enough: the conversation pane and the terminal status bar are never
    /// both on screen for the same selection at once.
    @ObservedObject var fallbackPRLadder: PRLadderModel

    @StateObject private var model: SessionPaneModel
    /// Scroll state shared with `ConversationWebView`. Held here so the chrome
    /// can show the "new output" affordance when the reader is scrolled up.
    @StateObject private var scrollState = ConversationScrollState()
    /// Drives the background-activity dot, separate from the phase pulse: it
    /// animates whenever that indicator is on screen, regardless of phase.
    @State private var bgPulsing = false

    /// Silence shorter than this is just a turn in progress and needs no
    /// commentary. Past it, the wait is long enough that a reader starts to
    /// wonder, which is exactly when the number helps.
    nonisolated static let quietThreshold: Double = 20

    /// How many characters the pinned-message bar's own label keeps before
    /// cutting, independent of SwiftUI's `lineLimit(1)`.
    ///
    /// THIS IS A SECOND, CONTENT-LEVEL TRUNCATION, not a substitute for the
    /// view's width-based one — the two do different jobs. `lineLimit` decides
    /// what fits the capsule at whatever width and text scale the pane
    /// happens to be at, which is not knowable here. This bound exists so the
    /// truncation is visible EVEN TO A TEST: a pure function can assert an
    /// ellipsis lands on a long string, where a hosted view's pixel-width
    /// clipping cannot be asserted without a live layout pass. 120 characters
    /// is comfortably past what a capsule this wide shows at any text scale,
    /// so in practice the view's own clipping is what a reader actually sees;
    /// this bound only matters for holding the "still visibly a truncation"
    /// property under test.
    nonisolated static let pinnedPreviewMaxLength = 120

    /// Collapses whitespace (a held or released message can carry newlines)
    /// and cuts to `pinnedPreviewMaxLength`, appending `…` when it does.
    ///
    /// THE ELLIPSIS IS THE POINT. The plan names the hazard directly: `"don't
    /// ship the migration without the backfill"` truncated at the wrong place
    /// reads as a complete, stricter instruction than the one actually sent.
    /// A visible mark that something was cut is what keeps a truncated
    /// preview from being read as the whole message.
    nonisolated static func pinnedPreview(_ text: String) -> String {
        let collapsed = SessionPaneView.collapsedWhitespace(SessionPaneView.displayable(text))
        guard collapsed.count > pinnedPreviewMaxLength else { return collapsed }
        return "\(collapsed.prefix(pinnedPreviewMaxLength))…"
    }

    /// The accessibility label for the pinned-message bar: the FULL text,
    /// whitespace-collapsed but never cut — the one place VoiceOver reads the
    /// complete message rather than whatever `pinnedPreview` fit on one line,
    /// so a reader relying on it is never handed the truncated-reads-as-
    /// complete hazard `pinnedPreview`'s doc names.
    nonisolated static func pinnedAccessibilityLabel(_ text: String) -> String {
        "Scroll to your message: "
            + SessionPaneView.collapsedWhitespace(SessionPaneView.displayable(text))
    }

    /// The bidi controls that reorder rendered text.
    ///
    /// LISTED EXPLICITLY RATHER THAN TAKEN FROM A CATEGORY, and the first
    /// version of this guard got that wrong. Dropping general-category `Cf`
    /// covers these — and also covers the zero-width joiner, which legitimate
    /// emoji are BUILT from: it turned a family into four separate people and a
    /// pride flag into a white flag beside a rainbow. The category is the wrong
    /// unit because it groups "reorders what you read" with "is load-bearing
    /// content". Found by testing the filter against real emoji rather than by
    /// reading the category's definition.
    nonisolated static let bidiControls: Set<Unicode.Scalar> = [
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{200E}", "\u{200F}", "\u{061C}",
    ]

    /// How many scalars one grapheme cluster may carry before the rest are
    /// dropped.
    ///
    /// PER CLUSTER, NOT PER BASE, and the difference is the whole guard. A
    /// per-base mark counter is defeated by interleaving: `U+200D` is neither a
    /// mark nor a bidi control, so it resets the counter — while UAX #29 GB9
    /// forbids a cluster boundary immediately before `Extend` or `ZWJ`, so the
    /// cluster never actually ends. Base plus four-marks-then-joiner repeated
    /// 800 times measured 4,001 scalars in ONE cluster, passing the previous
    /// guard completely untouched and sailing under the 120-cluster bound
    /// uncut. Found in round 3 of security review on #88.
    ///
    /// The cluster is the unit the renderer lays out for one glyph position, so
    /// bounding it bounds the cost directly, whatever composed it — marks,
    /// joiners, tag characters, variation selectors.
    ///
    /// Sixteen is twice the worst legitimate cluster measured: the
    /// woman-heart-kiss-man sequence is 8 scalars, the Scotland flag's tag
    /// sequence and the four-person family are 7, and every stacking script
    /// checked (Thai, Vietnamese, Devanagari, Hebrew, Arabic) is at most 4. The
    /// ceiling this puts on a preview is 120 clusters times 16.
    nonisolated static let maxScalarsPerCluster = 16



    /// Drops the scalars that let displayed text disagree with sent text.
    ///
    /// THE SAME SAFETY PROPERTY AS THE ELLIPSIS, BY TWO OTHER MECHANISMS, which
    /// is why it lives beside it. `pinnedPreview`'s doc names the hazard as
    /// truncation: a message cut in the wrong place reads as a complete,
    /// stricter instruction. Both of these reach the same end without cutting.
    ///
    /// **Reordering.** `Text` and the accessibility label implement the Unicode
    /// bidi algorithm, so a `U+202E` anywhere before the cut reverses the run
    /// after it and the bar shows a sentence nobody sent. Truncation-safety
    /// cannot help, because the override does not need to survive the cut. The
    /// set dropped here is exactly Unicode's `Bidi_Control=Yes`.
    ///
    /// **An unbounded cluster.** `pinnedPreviewMaxLength` counts grapheme
    /// clusters, and one cluster absorbs any number of scalars, so a payload
    /// built as a single cluster is never truncated and never gets an ellipsis.
    /// It reaches the pill as one glyph stack rendering over its neighbours.
    /// See `maxScalarsPerCluster` for why the bound is per cluster; two earlier
    /// versions of this guard bounded the wrong thing and were defeated.
    ///
    /// Everything else is left alone. This is a display-fidelity guard rather
    /// than a sanitiser: the transcript's content is the pane's subject, and
    /// rewriting it past what makes the display honest would be its own lie.
    /// The joiner in particular STAYS — it is what emoji sequences are built
    /// from, and dropping it turned a family into four separate people.
    nonisolated static func displayable(_ text: String) -> String {
        // STRIP FIRST, THEN SEGMENT, THEN REPLACE — never truncate in place.
        //
        // THE INVARIANT THIS ESTABLISHES: every cluster of the stripped input
        // maps to exactly one cluster of the output, either itself unchanged or
        // a single replacement character. So the output re-segments to exactly
        // what was intended, and that is a property rather than a patch.
        //
        // FIVE ROUNDS OF SECURITY REVIEW GOT HERE, and each defeat had the same
        // shape: a transform that was locally correct per cluster produced a
        // boundary the reader re-segmented differently.
        //
        //   * marks per base — a ZWJ reset the counter without ending the
        //     cluster, so four marks then a joiner, repeated, was 4,001 scalars
        //     in one cluster;
        //   * scalars per INPUT cluster, counted on the OUTPUT — stripping the
        //     bidi controls removed the separators and the survivors coalesced,
        //     3,750 scalars in one cluster;
        //   * a truncated cluster's remnant pairing FORWARD — two clusters each
        //     capped and trimmed to a bare regional indicator re-paired into
        //     🇦🇨, a flag present nowhere in the message.
        //
        // The last one is why nothing is truncated in place any more. Trimming
        // guarded against scalars that attach BACKWARD; a regional indicator
        // pairs FORWARD and is neither a mark nor a joiner, so it slipped the
        // guard. Emitting a whole cluster or none removes the category: there is
        // no remnant to pair in either direction.
        //
        // The replacement character is deliberate rather than dropping the
        // cluster silently. `pinnedPreview`'s doc names the hazard as a cut that
        // reads as complete; a visible mark that something was here holds the
        // same property one level down.
        let stripped = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !SessionPaneView.bidiControls.contains($0) }))
        var out = String.UnicodeScalarView()
        for cluster in stripped {
            if String(cluster).unicodeScalars.count > SessionPaneView.maxScalarsPerCluster {
                out.append("\u{FFFD}")
            } else {
                out.append(contentsOf: String(cluster).unicodeScalars)
            }
        }
        return String(out)
    }

    private nonisolated static func collapsedWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The clamp `quietLabel` and `VitalsRow`'s staleness marker both tier
    /// against: a day, past which the exact count tells a reader nothing a
    /// mini restarting or a clock skew wouldn't invent anyway. Shorter than
    /// `WorkingStrip.durationLabel`'s week — that label survives a co's
    /// written-once "working on" line going stale over a weekend, while
    /// these two describe a session that is either actively quiet or has an
    /// unrefreshed terminal, neither of which stays meaningful that long.
    nonisolated static let quietClamp: Double = 86_400

    /// `nonisolated`: pure functions of a number, reaching no view state. The
    /// main actor would buy nothing and would force every caller onto it.
    nonisolated static func quietLabel(_ age: Double) -> String {
        "quiet \(WorkingStrip.tieredDuration(age, maxSeconds: quietClamp))"
    }

    init(session: String, displayName: String, appearance: Appearance,
         sendKey: SendKeyPreference = .default,
         canvas: String? = nil,
         accent: RGB? = nil,
         isLaunching: Bool = false,
         textScale: Double = 1,
         sessionLineHeight: Double = SessionTypography.default.lineHeight,
         composerTypography: ComposerTypography = .default,
         target: SSHTarget,
         draftStore: SessionDraftStore,
         draftKey: SessionRef,
         onFallBackToTerminal: @escaping () -> Void,
         onDeckOpen: ((DeckOpenRef.Origin) -> Void)? = nil,
         onStop: @escaping () -> Void = {},
         onGateChange: @escaping (Bool) -> Void = { _ in },
         hosts: [HostEntry],
         workingOn: SessionState.WorkingOn? = nil,
         findBarState: FindBarState,
         sharedPRLadder: PRLadderModel,
         fallbackPRLadder: PRLadderModel) {
        self.session = session
        self.displayName = displayName
        self.appearance = appearance
        self.sendKey = sendKey
        self.canvas = canvas
        self.accent = accent
        self.isLaunching = isLaunching
        self.textScale = textScale
        self.sessionLineHeight = sessionLineHeight
        self.composerTypography = composerTypography
        self.onFallBackToTerminal = onFallBackToTerminal
        self.onDeckOpen = onDeckOpen
        self.onStop = onStop
        self.onGateChange = onGateChange
        self.hosts = hosts
        self.workingOn = workingOn
        self.sharedPRLadder = sharedPRLadder
        self.fallbackPRLadder = fallbackPRLadder
        self.findBarState = findBarState
        _model = StateObject(wrappedValue: SessionPaneModel(
            session: session, target: target, draftStore: draftStore, draftKey: draftKey))
    }

    /// The colour of the frame strips — the status line above the conversation,
    /// and the live bar and composer below it. The session's canvas colour pushed
    /// halfway to the appearance's extreme: a shade lighter than the page in light
    /// mode, a shade darker in dark, so the chrome reads as the same surface as
    /// the conversation rather than a grey box bolted to it. nil when there is no
    /// canvas to derive from, which leaves the strips their default.
    ///
    /// A plain channel mix is what "halfway between two colours" means where a
    /// person would set it, in a colour picker. The canvas is already a gentle
    /// tint, so half again toward white or black is a frame in the same family
    /// that does not compete with the page it borders.
    private var frameTint: Color? {
        SessionPaneView.frameTintRGB(canvas: canvas, appearance: appearance).map(Color.init)
    }

    /// The surface the frame's text is drawn on, which is what an ink must be
    /// solved against. Falls back to the window's own background when the
    /// session has no canvas, because that is what the strips show then.
    private var inkSurface: RGB {
        SessionPaneView.frameTintRGB(canvas: canvas, appearance: appearance)
            ?? (appearance == .dark ? RGB(red: 0.12, green: 0.12, blue: 0.13)
                                    : RGB(red: 0.98, green: 0.98, blue: 0.98))
    }

    /// A failure, at 4.5:1 against that surface. Measured across all ten themes
    /// in both appearances: system `.orange` bottomed out at 2.11:1.
    private var errorInk: Color { Color(ThemeRecipe.errorInk(on: inkSurface)) }

    /// A standing state that is not a failure, at the same ratio and a hue far
    /// enough away that the two do not read as one signal.
    private var warningInk: Color { Color(ThemeRecipe.warningInk(on: inkSurface)) }

    /// "Waiting on the operator" — the same ink `CockpitView.pullRequestSeverityInk`
    /// gives `PRLadderRow.Severity.invitation`, solved here rather than
    /// there so the PR chip's "ready to merge" reads in the identical ink
    /// the cockpit panel draws it in.
    private var attentionInk: Color { Color(ThemeRecipe.attentionTextInk(on: inkSurface)) }

    /// The crew's own hue, made legible as Send's filled background —
    /// `ComposerView.primaryBackground` used to draw this as
    /// `Color.accentColor`, the system blue, on every crew alike. Falls back
    /// to `neutralAccent` the same way `liveBar`'s dot does when the shell
    /// has no theme for this session.
    private var progressFillInk: Color {
        Color(ThemeRecipe.accentFillInk(accent: accent ?? SessionPaneView.neutralAccent(appearance)))
    }

    /// The mix, as a pure function so it can be tested without a view. nil when
    /// the canvas is absent or not a hex colour — the strips fall back to their
    /// default rather than to a guessed colour.
    nonisolated static func frameTintRGB(canvas: String?, appearance: Appearance) -> RGB? {
        guard let canvas, let rgb = parseHexColor(canvas) else { return nil }
        // Halfway to white in light mode, to black in dark. `target` is the
        // extreme each channel is pulled toward.
        let target = appearance == .dark ? 0.0 : 1.0
        return RGB(red: (rgb.red + target) / 2,
                   green: (rgb.green + target) / 2,
                   blue: (rgb.blue + target) / 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .background(frameTint ?? Color.clear)
            Divider()
            // Sits below the status bar and above the transcript — the same
            // position Safari and Xcode draw theirs in. `findBarState` is
            // the one instance `ContentView` also hands the main pane's
            // `TerminalFindBar`, so opening it here and later switching to
            // Terminal View keeps the SAME bar rather than opening a second
            // one underneath it.
            if findBarState.isPresented {
                ConversationFindBar(state: findBarState, scrollState: scrollState)
                Divider()
            }
            ZStack(alignment: .bottom) {
                ConversationWebView(html: model.html,
                                   scrollState: scrollState,
                                   pendingDelta: model.pendingDelta,
                                   onDeltaApplied: model.deltaApplied,
                                   onDeltaFailed: model.deltaFailed,
                                   onCursorRead: model.cursorRead,
                                   onDeckOpen: onDeckOpen,
                                   hosts: hosts)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // "New output" affordance: shown when the reader has scrolled
                // up into history and new turns have arrived. Clicking returns
                // them to the newest content without disturbing the reload
                // that set this flag.
                if scrollState.hasNewOutput {
                    Button { scrollState.scrollToBottom() } label: {
                        Label("New output", systemImage: "arrow.down")
                            .frameFont(.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderless)
                    .background(Capsule().fill(Material.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2),
                                                   lineWidth: 1))
                    .padding(.bottom, 12)
                }
                // The pinned last message: the same grammar as "New output"
                // above, pointing the other way. Both are navigation, not
                // delivery — this one for a message the reader typed that has
                // scrolled off the top, the other for output that arrived
                // below. Same capsule, material and stroke as the pill; see
                // `SessionPaneView.pinnedPreview` for why the label is a
                // second, independent truncation rather than relying on
                // `lineLimit` alone.
                if let pinned = scrollState.pinnedMessage {
                    Button { scrollState.scrollToPinnedMessage() } label: {
                        Label(SessionPaneView.pinnedPreview(pinned.text), systemImage: "arrow.up")
                            .frameFont(.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderless)
                    .background(Capsule().fill(Material.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2),
                                                   lineWidth: 1))
                    .accessibilityLabel(SessionPaneView.pinnedAccessibilityLabel(pinned.text))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            // The live state sits directly above the box you type in, with no
            // divider between them, because they are one thing: what the session
            // is doing and what you can say to it. The operator asked for the pulse "right
            // by the input prompt window" — at the top of the pane it was a
            // ceiling away from where a waiting reader is actually looking.
            //
            // Both carry the frame tint, so the live bar and the composer read as
            // one continuous strip below the conversation rather than two.
            liveBar
                .background(frameTint ?? Color.clear)
            composer
                .background(frameTint ?? Color.clear)
        }
        .task { await model.start(appearance: appearance, canvas: canvas,
                                  scale: textScale,
                                  lineHeight: sessionLineHeight) }
        .onChange(of: appearance) { _, new in
            // The shell resolved a new appearance, so the document is re-rendered
            // with the new stamp rather than being left to notice on its own.
            Task { await model.reRender(appearance: new, canvas: canvas) }
        }
        // The canvas moves without the appearance moving: remapping this
        // session's theme changes the colour while the OS setting stands still.
        // `.task` does not re-fire, because the pane's identity is the session
        // name and that has not changed — so without this the model keeps the
        // colour it was born with and every later render carries it.
        .onChange(of: canvas) { _, new in
            Task { await model.reRender(appearance: appearance, canvas: new) }
        }
        // Cmd-+/- moved the terminal and did nothing here, which read as a dead
        // shortcut rather than one that does not apply. Now the same preference
        // re-renders the page at the new size.
        .onChange(of: sessionLineHeight) { _, new in
            Task { await model.reRender(appearance: appearance, lineHeight: new) }
        }
        .onChange(of: textScale) { _, new in
            Task { await model.reRender(appearance: appearance, scale: new) }
        }
        // On each poll tick, clear the "new output" pill if the reader has
        // already scrolled back to the bottom. `onChange(of: model.state)` is
        // not enough here: `SessionState` is Equatable and a quiet poll leaves
        // state unchanged, so the onChange closure would never fire after output
        // stops — exactly the moment the reader catches up and the pill should
        // clear. `pollCount` is a monotonic counter incremented unconditionally
        // on each tick.
        .onChange(of: model.pollCount) { _, _ in
            scrollState.checkAndClearIfAtBottom()
            scrollState.checkPinnedMessage()
        }
        // Compared as a `Bool` rather than on `model.state.gate` itself, so
        // this fires once per OPEN/CLOSE transition rather than on every
        // reading that merely changes which question is showing — the rail
        // only needs to know whether ⌘1-9 collides with `GatePanel`'s own
        // bindings, not which gate is up. Fires on both directions: opening
        // AND closing, which is what lets `RailStateModel.hasOpenGate`
        // recover immediately rather than only suppress immediately — see
        // `onGateChange`'s doc.
        .onChange(of: model.state.gate != nil) { _, hasGate in
            onGateChange(hasGate)
        }
    }

    // MARK: - Status

    /// The top of the pane: what the terminal keeps in its status area, the
    /// co's own working-on sentence, and the crew's identity, merged into one
    /// row.
    ///
    /// The operator: "take all the things from the status area of the TUI, and put them in
    /// the frame of Deck, so they are visible even in the session view." Reading
    /// the conversation here meant giving up the line that says how much context
    /// is left, which subscription is paying, whether the phone can reach this
    /// session, what is running under it, and which model is answering.
    ///
    /// **One row, not three.** The pane used to stack a working-on strip above
    /// this bar, which used to sit below a separate pane-chrome row of its
    /// own — three ~26pt rows before the conversation even began. `PaneStatusBar`
    /// now carries all of it: the crew's mark and name, then one flexible slot
    /// for the working-on sentence UNLESS something more urgent pre-empts it,
    /// then the vitals. See `PaneStatusBar`'s own doc for the slot's precedence
    /// and `design/redesign/01-window.html`/`05-states.html` for the shape.
    private var statusBar: some View {
        PaneStatusBar(
            mark: model.state.mark,
            displayName: displayName,
            dotAccent: accent ?? SessionPaneView.neutralAccent(appearance),
            dotSurface: inkSurface,
            workingOn: workingOn,
            vitals: model.state.vitals,
            agentsAreFleetWide: model.state.agentsAreFleetWide,
            isLaunching: isLaunching,
            phase: model.state.phase,
            renderError: model.renderError,
            reason: model.state.reason,
            alive: model.state.alive,
            warningInk: warningInk,
            errorInk: errorInk,
            attentionInk: attentionInk,
            prChip: prChipPresentation,
            onRefresh: { model.refresh() },
            onStop: onStop)
    }

    /// The PR chip's ladder position, put on the same derivation
    /// `CockpitView`'s Pull Requests panel draws from — see
    /// `SessionReviewChip.presentation`'s doc for the reuse-vs-fallback
    /// choice this makes between `sharedPRLadder` and `fallbackPRLadder`.
    private var prChipPresentation: PRLadderRow.Presentation? {
        guard let pr = model.state.vitals?.pr else { return nil }
        return SessionReviewChip.presentation(
            for: pr,
            sharedReadings: sharedPRLadder.coveredReadings,
            fallbackResult: fallbackPRLadder.result)
    }

    /// REDUCE MOTION, AND WHY THE DOT CANNOT SIMPLY STOP. The pulse is not
    /// decoration: a working turn can spend minutes inside one tool call with
    /// nothing reaching the conversation, and a STATIC dot beside a static
    /// "Working" is exactly what the pulse was built to stop — indistinguishable
    /// from a wedged session. Honouring the setting by deleting the animation
    /// would hand that ambiguity straight back to the reader who asked for less
    /// motion.
    ///
    /// So the information moves rather than disappearing. With motion reduced,
    /// the quiet counter appears as soon as the session is working instead of
    /// waiting for the threshold, and a number that advances on every poll says
    /// "alive, and silent this long" without anything sliding or throbbing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the live bar's dot draws in when the shell has no theme for this
    /// session. A mid grey rather than `.secondary`, so it is a real colour the
    /// shapes can be filled with in either appearance.
    nonisolated static func neutralAccent(_ appearance: Appearance) -> RGB {
        appearance == .dark
            ? RGB(red: 0.62, green: 0.62, blue: 0.64)
            : RGB(red: 0.42, green: 0.42, blue: 0.44)
    }

    /// The line directly above the composer: what the session is doing right now.
    private var liveBar: some View {
        HStack(spacing: 8) {
            // THE PULSE. The operator: "a pulse when claude is working but no output is
            // coming to the session surface." A working turn can spend minutes
            // inside one tool call with nothing reaching the conversation, and a
            // static dot beside a static "Working" is indistinguishable from a
            // wedged session — the reader has no way to tell thinking from
            // stuck. Motion is the difference, and it costs no extra polling:
            // the state already carries what it needs.
            //
            // The same vocabulary the rail uses, drawn by the same view and in
            // the same colour, so the dot on the row that opened this pane and
            // the dot above its composer are one mark seen twice. Both surfaces
            // draw every state now, including ready — there is no longer a case
            // where one shows something and the other shows nothing.
            SessionDotView(mark: model.state.mark,
                           accent: accent ?? SessionPaneView.neutralAccent(appearance),
                           surface: inkSurface, size: 11)
            Text(model.state.liveLabel)
                .frameFont(.live)
            // Still moving while the label says idle or waiting: a subagent
            // working on while the main agent looks done. Without this a
            // "Waiting for you" beside ongoing background work reads as "your
            // turn, nothing happening" — the confusion the operator hit. Its own pulse,
            // separate from the phase dot, because the phase is genuinely
            // waiting; this says something else still is not.
            if model.backgroundActivity {
                HStack(spacing: 4) {
                    // This one loses nothing when it stops: the sentence beside
                    // it already says what the motion was hinting at, which the
                    // phase dot has no equivalent of.
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 1 : (bgPulsing ? 0.25 : 1))
                        .animation(reduceMotion ? .default
                                   : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                   value: bgPulsing)
                    Text("working in the background")
                        .frameFont(.body).foregroundStyle(.secondary)
                }
                .help("A subagent is still writing while the main agent waits")
                // Reset on disappear so the next appearance is a real false→true
                // transition. Without it `bgPulsing` stays true, `onAppear` sets
                // true→true, the animation's `value:` sees no change, and the dot
                // comes back stuck dim instead of pulsing. Caught by deck-reviewer.
                .onAppear { bgPulsing = true }
                .onDisappear { bgPulsing = false }
            }
            // How long it has been quiet. The pulse says "alive"; this says how
            // long alive-and-silent has lasted, which is what turns a worrying
            // wait into an informed one. Shown only past a threshold, so an
            // ordinary responsive turn is not cluttered with a ticking number.
            if model.state.phase == .working, let age = model.state.lastEventAge,
               age >= SessionPaneView.quietThreshold || reduceMotion {
                Text(SessionPaneView.quietLabel(age))
                    .frameFont(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // What the last thing you did came back with. Nothing displayed this
            // before, so a refused message and a refused answer both looked like
            // a button that did nothing at all.
            if let lastError = model.lastError {
                Text(lastError)
                    .frameFont(.body).foregroundStyle(errorInk)
                    .lineLimit(1).truncationMode(.tail)
                    .help(lastError)
            }
            Spacer()
            // Interrupt used to sit here, right-aligned one row above Send. It
            // now lives in the composer's control bar as its own bordered
            // button, present exactly while a turn runs.
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        if let gate = model.state.gate {
            GatePanel(gate: gate,
                      question: model.currentQuestion,
                      questionIndex: model.questionIndex,
                      questionsRemaining: model.questionsRemaining,
                      ticked: model.ticked,
                      isAwaitingSubmit: model.isAwaitingSubmit,
                      choiceCommit: model.choiceCommit,
                      freeTextRow: model.freeTextRow,
                      freeText: $model.freeText,
                      onChoose: { option, multiSelect in
                          model.choose(option, multiSelect: multiSelect)
                      },
                      onSubmit: { model.submitChoices() },
                      onSubmitAnswers: { model.submitAnswers() },
                      onAnswerWithText: { model.answerWithText(model.freeText) },
                      onFallBackToTerminal: onFallBackToTerminal)
        } else if let message = SessionPaneModel.composerFallbackMessage(for: model.state.phase) {
            // Blocked or unknown, both with nothing renderable. Saying so and
            // offering the terminal is honest; an empty dialog would be the
            // lie. `composerFallbackMessage` carries the distinct wording for
            // the two phases — see its doc comment for why they must differ.
            HStack {
                Text(message).frameFont(.emphasis)
                Button("Open terminal", action: onFallBackToTerminal).frameFont(.emphasis)
            }
            .padding(10)
        } else {
            ComposerView(
                text: $model.draft,
                enabled: model.state.phase.acceptsMessage && !model.sending,
                sendKey: sendKey,
                tint: frameTint,
                errorInk: errorInk,
                progressFillInk: progressFillInk,
                onSend: { model.send() },
                isWorking: model.state.phase == .working,
                onInterrupt: { model.interrupt() },
                heldCount: model.state.held,
                onRewrite: { model.rewrite() },
                isRewrite: model.isRewrite,
                commands: model.commands,
                commandsError: model.commandsError,
                loadingCommands: model.loadingCommands,
                onOpenCommands: { model.loadCommands() },
                onPickCommand: { model.insertCommand($0) },
                typography: composerTypography
            )
            .padding(10)
        }
    }
}

/// The pane's status row, taking plain values rather than reading `model`
/// directly — not `private`, for the same reason `GatePanel` is not: so a
/// test can host it in an `NSHostingView` with a fixture no live session ever
/// produces (every vitals field populated, at the largest frame typography)
/// and measure whether the crowded `HStack` — the crew's mark and name, a
/// status line, vitals, refresh, the session menu —
/// still fits a pane at its narrowest real width, rather than that being a
/// thing only the operator discovers by resizing the window.
///
/// **ONE ROW, WHERE THREE STOOD BEFORE** (`design/redesign/01-window.html`).
/// Leading, the crew's own mark and name, so the pane still says whose
/// conversation this is once the rail collapses to marks with no names
/// (`design/redesign/04-narrow.html`, below 1280pt). Then one flexible slot:
/// the co's working-on sentence, UNLESS the pane has something more urgent to
/// say, in which case that pre-empts it in the same slot, in order —
///
///   1. `renderError`, in the error ink: the pane could not draw the
///      conversation at all, which outranks anything about what the session
///      is doing.
///   2. `"Starting…"`, while `isLaunching` and the phase has not resolved:
///      the session does not exist yet, so the poll's "cannot reach" reason
///      is expected rather than a fault.
///   3. `reason`, while the phase is still `.unknown`: the mini could not be
///      reached, and this is why.
///   4. Otherwise the working-on sentence, with its age when the recording
///      says it is stale — see `WorkingStrip.durationSuffix`.
///
/// These first three are `PaneStatusBar`'s pre-existing text slot and they
/// are not new: they are the mid-launch and unreachable-host cases, and
/// exactly what a reader needs when the pane is blank. Trailing, the vitals,
/// unchanged in what they carry — see `VitalsRow`.
///
/// **TWO STALENESS FACTS, NOT ONE.** `workingOn.stale` comes from
/// `co-working-on` and ages the working-on sentence, drawn amber past twenty
/// minutes; `vitals.stale` comes from the terminal's own redraw and ages the
/// vitals cluster's trailing "· as of 4m ago" (`VitalsRow`). They read
/// different pollers and can disagree — a session can be mid-turn (fresh
/// vitals) while the co has not confirmed a line in a while, or vice versa —
/// so collapsing them into one age would misreport whichever poller was not
/// asked.
struct PaneStatusBar: View {
    /// The session's own dot, the same vocabulary the rail draws — see
    /// `SessionState.Mark`.
    let mark: SessionState.Mark
    /// The crew or child's human name, resolved the same way every other
    /// surface resolves it — see `SessionPaneView.displayName`.
    let displayName: String
    /// The dot's colour and the surface it draws on, threaded rather than
    /// resolved here for the same reason `SessionPaneView.liveBar`'s dot
    /// takes them: so the mark above the conversation and the one on the
    /// rail row that opened this pane are provably one colour.
    let dotAccent: RGB
    let dotSurface: RGB
    /// The co's own recording — see `SessionPaneView.workingOn`.
    let workingOn: SessionState.WorkingOn?
    let vitals: SessionState.Vitals?
    /// Whether the agents `vitals.agentsLabel` names are dispatched
    /// fleet-wide rather than for this session's own crew — carried
    /// alongside `vitals` rather than read off it, because the flag now
    /// lives at the top level of `SessionState` (see
    /// `SessionState.agentsAreFleetWide`) so it survives the day the
    /// producer deletes its deprecated copy inside `vitals`. Defaulted to
    /// `false` so the existing fixture-driven test, which has no reason to
    /// care about scope, keeps compiling unchanged.
    var agentsAreFleetWide: Bool = false
    let isLaunching: Bool
    let phase: SessionState.Phase
    let renderError: String?
    let reason: String?
    let alive: Bool
    /// Solved by the pane against the tint this row sits on, rather than
    /// picked here — see `VitalsRow.warningInk`.
    let warningInk: Color
    let errorInk: Color
    /// "Waiting on the operator" — passed through to `VitalsRow`'s PR chip alongside
    /// `warningInk`/`errorInk`, on the same "solved by the pane" footing.
    let attentionInk: Color
    /// The PR chip's ladder position, put on `SessionPaneView.prChipPresentation`'s
    /// derivation — nil draws the chip's plain "PR #N" fallback.
    let prChip: PRLadderRow.Presentation?
    var onRefresh: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                SessionDotView(mark: mark, accent: dotAccent, surface: dotSurface, size: 10)
                Text(displayName)
                    .frameFont(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            // THE FLEXIBLE SLOT. `.frame(maxWidth: .infinity)` makes this the
            // one child of the row with an unbounded proposed width, which is
            // what makes it the one that gives way first as the pane narrows
            // — the crew's mark and name and the vitals cluster both propose
            // their own ideal width and hold it until this has nothing left
            // to give. See `04-narrow.html`: "the status slot is never
            // dropped."
            slot
                .frame(maxWidth: .infinity, alignment: .leading)
            if let vitals {
                VitalsRow(vitals: vitals, agentsAreFleetWide: agentsAreFleetWide, warningInk: warningInk,
                          errorInk: errorInk, attentionInk: attentionInk, prChip: prChip)
            }
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Re-render the conversation")
            // BEHIND A MENU, because it is the one irreversible thing this pane
            // can do and it used to sit inline beside the two most-clicked
            // buttons. Stop kills the tmux session: the agent is asked to exit
            // and the scrollback goes with it. Interrupt, which merely ends the
            // turn, was a row away and named similarly — so the cheap action and
            // the destructive one were a slip apart. The menu makes reaching
            // this deliberate; the confirmation behind it is unchanged.
            //
            // Only while there is an agent to stop. A session with no live agent
            // shows a Start affordance instead (the shell swaps the whole pane),
            // so a Stop here would be an action with nothing to act on — and an
            // empty menu is worse than no menu.
            if alive {
                Menu {
                    Button("Stop session", role: .destructive, action: onStop)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Session actions")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The one flexible slot, in the precedence this type's doc states. Every
    /// branch shares `lineLimit(1)`/`.truncationMode(.tail)`, so whichever one
    /// draws truncates the same way rather than only the branch someone
    /// happened to test.
    @ViewBuilder
    private var slot: some View {
        if let renderError {
            Text(renderError)
                .frameFont(.body).foregroundStyle(errorInk)
                .lineLimit(1).truncationMode(.tail)
                .help(renderError)
        } else if isLaunching, phase == .unknown {
            // A start is in flight; the session does not exist yet, so the
            // poll's "cannot reach" reason is expected rather than a fault.
            Text("Starting…").frameFont(.body).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        } else if let reason, phase == .unknown {
            Text(reason).frameFont(.body).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        } else if let workingOn,
                  // TRIMMED, so a whitespace-only recording draws nothing
                  // rather than an empty-but-present line — and so this
                  // agrees with `WaypointRibbon.isWorkLive`, which trims too.
                  // The two surfaces read ONE recording and must not
                  // disagree about whether it says anything (`deck-reviewer`,
                  // PR #140).
                  !workingOn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workingOnRow(workingOn)
        }
    }

    private func workingOnRow(_ workingOn: SessionState.WorkingOn) -> some View {
        HStack(spacing: 6) {
            Text(workingOn.text)
                .frameFont(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            if let suffix = WorkingStrip.durationSuffix(for: workingOn) {
                Text(suffix)
                    .frameFont(.body)
                    // Amber exactly when `workingOn.stale` says the co has
                    // not confirmed this line in twenty minutes — the
                    // reader's cue that the sentence itself, not only the
                    // vitals, may be out of date. See this type's doc for why
                    // this is a different fact from `vitals.stale`.
                    .foregroundStyle(workingOn.stale == true ? warningInk : Color.secondary)
            }
        }
        .help(workingOn.text)
    }
}

/// The terminal's status area, as native chrome.
///
/// Each fact is drawn only when the mini could establish it. A pane that showed
/// `ctx 0/? (0%)` for a session whose reading had not arrived would be reporting
/// an empty context rather than an absent measurement, and the whole reason these
/// numbers are worth carrying across is that they are the ones being trusted.
private struct VitalsRow: View {
    let vitals: SessionState.Vitals
    /// See `PaneStatusBar.agentsAreFleetWide` — the top-level flag, carried
    /// in rather than read off `vitals`.
    var agentsAreFleetWide: Bool = false
    /// Solved by the pane against the tint this row sits on, rather than picked
    /// here: the row cannot see the canvas, and a fixed colour is what put a
    /// standing badge in the failure ink in the first place.
    ///
    /// Undefaulted for the reason `ComposerView.typography` is: one call site,
    /// and a default that lets an unwired one compile.
    let warningInk: Color
    /// The PR chip's other two inks, on `warningInk`'s own footing — passed
    /// in rather than solved here for the same reason.
    let errorInk: Color
    let attentionInk: Color
    /// The PR chip's ladder position — see `SessionPaneView.prChipPresentation`'s
    /// doc. `nil` draws the chip's plain "PR #N" fallback rather than
    /// `review_state`, which this row no longer reads.
    let prChip: PRLadderRow.Presentation?

    /// WHAT SURVIVES A NARROW PANE, in order.
    ///
    /// The row is up to six items, each `lineLimit(1)`, sharing its line with
    /// the crew's mark and name, the working-on/status slot, and three
    /// buttons. Open the shell split and the session pane gets narrow;
    /// SwiftUI then compresses whichever subview it likes, and the likeliest
    /// casualty was the context percentage — the number this whole row
    /// exists to carry — while `3 in flight (fleet): a·b·c·+2` survived
    /// intact.
    ///
    /// Priority is stated rather than left to the layout engine: context first,
    /// then whether the session is reachable, then the PR, then the rest. The
    /// `.lineLimit(1)` that makes this hold is set once, on the row's own
    /// `HStack`, rather than repeated per item — an item built inline instead
    /// of through `item(...)` inherits it too, so the ones that lose priority
    /// truncate rather than wrap the row onto a second line.
    ///
    /// This ladder is not the only mechanism, though: billing's `.fixedSize`
    /// (below) sits outside it entirely, holding its ideal width
    /// unconditionally rather than competing at `Priority.rest`. Measured at
    /// `ContentView.mainPaneMinWidth` against the crowded fixture
    /// (`PaneStatusBarTests.crowdedVitals`, with a realistic working-on
    /// sentence): the model badge, nominally the same tier, still compresses
    /// to its bare hexagon icon there (17pt of a 186pt ideal) — `.fixedSize`
    /// only protects the one item wearing it, and does not extend the same
    /// exemption to `Priority.rest` siblings. Model is left unprotected on
    /// purpose: it has no bounded short form the way `vitals.subSlot` gives
    /// billing one, so giving it the same `.fixedSize` forces its full,
    /// unbounded model-id string and pushes the trailing session-actions
    /// menu button off the pane at this width (measured: the button's origin
    /// moves from x=370, safely inside the 400pt frame, to x=430) — an
    /// unreachable Stop control is a worse failure than an icon-only badge.
    private enum Priority {
        static let context: Double = 3
        static let remoteControl: Double = 2
        static let pr: Double = 1
        static let rest: Double = 0
    }

    var body: some View {
        HStack(spacing: 10) {
            // FIRST, not last: context is the vital that changes what you do
            // next, so it is the one `04-narrow.html` keeps to the end when
            // the rest give way — being first here is what a fixed
            // `Priority.context` above the others actually protects.
            // No meter: the tint carries the tier at a glance already
            // (`vitals.tierTint`, below), and `contextHelp` escalates in
            // words on hover — the meter was 44pt plus 6pt of spacing spent
            // restating a fact the text already states (the operator, 2026-09-08).
            if let context = vitals.contextLabel {
                Text(context).frameFont(.body).monospacedDigit()
                    .foregroundStyle(vitals.tierTint)
                    .lineLimit(1)
                    .help(vitals.contextHelp)
                    .layoutPriority(Priority.context)
            }
            // Left unprotected on the narrowest pane, deliberately: this
            // shares billing's `Priority.rest` but not its `.fixedSize`, so
            // it can still compress to its bare hexagon icon (see this
            // type's doc comment for the measured numbers and why giving it
            // the same exemption is a worse trade). A bare model icon is a
            // smaller harm than a bare billing icon was — the model name
            // costs nothing to misread and the tooltip is one hover away,
            // where a misread billing token was a live $50 overnight
            // mistake (issue_01M1Y7A36AZ42VSK3QYZBYSNQD).
            if let model = vitals.model {
                item("hexagon", model, tint: .secondary,
                     help: "The main loop's model — dispatched agents run their own "
                         + "roster-resolved ones. Change it with /model.")
                    .layoutPriority(Priority.rest)
            }
            // Its own token, not folded into the model's tooltip: which
            // credential a session spends is the one vital that costs money
            // when misread, and a tooltip is not glanceable ($50 overnight,
            // issue_01M1Y7A36AZ42VSK3QYZBYSNQD).
            //
            // `.fixedSize` so a narrow pane drops this token whole rather
            // than truncating it: `vitals.subSlot` already reduces
            // `nyh (example-account)` to `nyh`, so there is no shorter form
            // left to fall back to, and `n…` would be a different account,
            // not a smaller answer for the same one. This exempts billing
            // from the `Priority.rest` competition entirely rather than
            // merely tying it with model there — the two no longer share a
            // fate under compression (deck-reviewer, PR #209).
            if let sub = vitals.sub {
                item("creditcard", vitals.subSlot ?? sub, tint: .secondary,
                     help: "Billing \(sub)")
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(Priority.rest)
            }
            // Shown in both states, deliberately. A badge that appears only when
            // remote control is on cannot be distinguished from a badge that has
            // not loaded — and "off" is the state the operator has been getting caught by,
            // so it is the one that has to be legible.
            if let on = vitals.remoteControlOn {
                item(on ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                     on ? "rc" : "rc off",
                     // NOT the error orange. This is a standing state, not a
                     // failure, and a permanent badge in the error colour either
                     // shouts forever or teaches the eye that orange is
                     // ignorable — and the eye needs orange to mean "a render or
                     // a send just failed". The slash in the icon carries the
                     // meaning; the colour only has to stop lying.
                     tint: on ? .secondary : warningInk,
                     help: on
                        ? "Reachable from your phone\(vitals.remoteName.map { " as \($0)" } ?? "")"
                        : "Remote control is off — this session is not reachable from your phone")
                    .layoutPriority(Priority.remoteControl)
            }
            if !vitals.agents.isEmpty {
                item("gearshape", vitals.agentsLabel(fleetWide: agentsAreFleetWide), tint: .cyan,
                     help: agentsAreFleetWide
                        ? "Dispatched agents alive across every repo"
                        : "Dispatched agents alive for this repo")
                    .layoutPriority(Priority.rest)
            }
            if let pr = vitals.pr {
                item("arrow.triangle.pull", SessionReviewChip.label(pr: pr, presentation: prChip),
                     tint: SessionReviewChip.tint(
                        presentation: prChip, warningInk: warningInk, errorInk: errorInk, attentionInk: attentionInk),
                     help: pr.url.map { "Working on \($0)" }
                        ?? "The PR this session is working on")
                    .layoutPriority(Priority.pr)
            }
            // Said once, at the end, rather than qualifying each number: the
            // whole reading is one snapshot and it is all equally old.
            if vitals.stale == true, let age = vitals.age {
                Text("· as of \(WorkingStrip.tieredDuration(age, maxSeconds: SessionPaneView.quietClamp)) ago")
                    .frameFont(.body).foregroundStyle(.tertiary)
                    .help("The terminal has not redrawn since; these numbers are that old")
                    .layoutPriority(Priority.rest)
            }
        }
        // Belt-and-suspenders with `item`'s own `.lineLimit(1)`: the marker
        // above is built inline rather than through `item`, precisely the gap
        // that let it wrap and grow the row's height when the pane narrowed
        // (a stale `shipwright` session, 2026-09-05). Setting the limit here
        // too means the row's own invariant — every element `lineLimit(1)` —
        // holds for whatever gets added inline next, not only for what
        // remembers to call `item`.
        .lineLimit(1)
    }

    private func item(_ symbol: String, _ text: String, tint: Color,
                      help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).frameFont(.icon)
            Text(text).frameFont(.body)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .help(help)
    }
}

extension SessionState.Vitals {
    /// `162K/1M (16%)`, or nil when there is no reading to show.
    ///
    /// Formatted the way the status line formats it, so the two read as one
    /// number in two places rather than as two measurements.
    var contextLabel: String? {
        guard let tokens = contextTokens else { return nil }
        var label = SessionState.Vitals.abbreviated(tokens)
        if let window = contextWindow, window > 0 {
            label += "/\(SessionState.Vitals.abbreviated(window))"
        }
        if let percent = contextPercent, percent.isFinite {
            // CLAMPED BEFORE THE CAST, not merely checked for NaN. `isFinite`
            // admits every finite Double, including ones past `Int.max`, and
            // `Int(_:)` precondition-TRAPS on those — so a `ctx_pct` of 1e100
            // would take the whole app down. The value comes from Claude Code's
            // status-line payload, which is not ours to constrain.
            //
            // This pane has already paid for this once, in `quietLabel`, where
            // an age of 1e30 would have trapped the same way. Caught again here
            // by deck-security-reviewer; the NaN test that shipped with it
            // covered the neighbouring case rather than this one.
            //
            // The bound is deliberately far above any real reading rather than
            // at 100: a genuine 120% is worth showing as 120%, and a nonsense
            // one reads as obviously nonsense rather than as a quietly
            // plausible number.
            label += " (\(Int(min(max(percent, 0), 9_999).rounded()))%)"
        }
        return label
    }

    /// `1M`, `162K`, `900`. The status line's own abbreviation.
    static func abbreviated(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions == millions.rounded()
                ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if count >= 1_000 { return "\(Int((Double(count) / 1000).rounded()))K" }
        return "\(count)"
    }

    /// The slot name out of `sub`'s `"slot (account)"`, e.g. `nyh` from `nyh
    /// (example-account)` — the token's label; the account stays in the
    /// tooltip. nil when `sub` doesn't have the `" ("` separator, so the
    /// caller falls back to the whole string rather than mangling it.
    var subSlot: String? {
        guard let sub, let parenIndex = sub.firstIndex(of: "(") else { return nil }
        let slot = sub[sub.startIndex..<parenIndex].trimmingCharacters(in: .whitespaces)
        return slot.isEmpty ? nil : slot
    }

    var tierTint: Color {
        switch tier {
        case .soft: return .yellow
        case .hard: return .orange
        case .corrupt: return .red
        case .ok, nil: return .secondary
        }
    }

    /// Why the context badge is coloured, in the words the status line uses. The
    /// thresholds are the mini's; this only names what it decided.
    var contextHelp: String {
        switch tier {
        case .soft: return "Context large — plan a handoff"
        case .hard: return "Degradation zone — hand off now"
        case .corrupt: return "Tool-call corruption seen — restart this session"
        case .ok, nil: return "Context used in this session"
        }
    }

    /// `fleetWide` is passed in rather than read off `self.agentsAreFleetWide`
    /// — see that field's doc: the top-level `SessionState.agentsAreFleetWide`
    /// is the reading callers should pass now.
    func agentsLabel(fleetWide: Bool) -> String {
        let scope = fleetWide ? SessionState.fleetWideSuffix : ""
        // The names matter more than the count when there are few, and the count
        // matters more when there are many — so both, with the list truncated
        // rather than the number.
        let shown = agents.prefix(3).joined(separator: "·")
        let rest = agents.count > 3 ? "·+\(agents.count - 3)" : ""
        return "\(agents.count) in flight\(scope): \(shown)\(rest)"
    }

}

/// The gate's own scrolling area, between the pane and the question.
///
/// THE FAULT THIS FIXES IS VERTICAL, and getting that wrong cost a round. The
/// operator reported "the text runs out of the box and there's no way to see it", which
/// reads as text overflowing sideways — it is not. An option's description
/// wraps at whatever width the pane proposes, both before this change and
/// after. What it did was make the gate TALLER than the composer's share of the
/// pane, and the pane's `VStack` clipped the excess with nothing to scroll: the
/// same fault as the Settings list in #52, one surface along.
///
/// "No way to see it" was the load-bearing half of the report.
///
/// A separate view rather than a `ScrollView` inline in the composer, so
/// `PickerTests` can host it and assert the content stays reachable. A scroll
/// view is invisible in a screenshot when the content happens to fit; the only
/// way to hold this fixed is to measure it with content that does not.
struct GatePanel: View {
    let gate: SessionState.Gate
    let question: SessionState.Question?
    let questionIndex: Int
    let questionsRemaining: Int
    let ticked: Set<Int>
    /// Every question answered, the gate waiting on its review tab.
    let isAwaitingSubmit: Bool
    /// What committing a multiselect would do — `submit` ends the gate, `next`
    /// saves the ticks and moves on. nil where the pane may not commit at all:
    /// a multi-question gate whose button nobody read, where the pane cannot tell
    /// which question is on screen.
    let choiceCommit: SessionState.Rendered.Commit?
    /// The row the TUI's `Type something.` sits on, when the mini saw one. nil
    /// means nobody established it, so no card is drawn.
    let freeTextRow: Int?
    @Binding var freeText: String
    var onChoose: (Int, Bool) -> Void
    var onSubmit: () -> Void
    var onSubmitAnswers: () -> Void
    var onAnswerWithText: () -> Void
    var onFallBackToTerminal: () -> Void

    /// The gate's ceiling. Past this the conversation above it would be squeezed
    /// to nothing by a question with a lot of options, so the gate scrolls
    /// instead of growing further.
    static let maximumHeight: CGFloat = 340

    var body: some View {
        ScrollView {
            GateView(gate: gate, question: question, questionIndex: questionIndex,
                     questionsRemaining: questionsRemaining, ticked: ticked,
                     isAwaitingSubmit: isAwaitingSubmit,
                     choiceCommit: choiceCommit,
                     freeTextRow: freeTextRow, freeText: $freeText,
                     onChoose: onChoose, onSubmit: onSubmit,
                     onSubmitAnswers: onSubmitAnswers,
                     onAnswerWithText: onAnswerWithText,
                     onFallBackToTerminal: onFallBackToTerminal)
                .padding(10)
        }
        .frame(maxHeight: GatePanel.maximumHeight)
    }
}

/// A question the session has stopped on, rendered from structured data.
///
/// The whole reason a GUI is possible: `PermissionRequest` carries the question,
/// its options and their descriptions as JSON, so these are real buttons rather
/// than a menu scraped off a terminal.
private struct GateView: View {
    let gate: SessionState.Gate
    /// The question on screen, and where it sits in the gate's sequence. The
    /// pane no longer assumes this is the first one — see `questionIndex`.
    let question: SessionState.Question?
    let questionIndex: Int
    let questionsRemaining: Int
    /// Which options this pane has ticked on a multiselect question.
    let ticked: Set<Int>
    let isAwaitingSubmit: Bool
    let choiceCommit: SessionState.Rendered.Commit?
    let freeTextRow: Int?
    @Binding var freeText: String
    var onChoose: (Int, Bool) -> Void
    var onSubmit: () -> Void
    var onSubmitAnswers: () -> Void
    var onAnswerWithText: () -> Void
    var onFallBackToTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isAwaitingSubmit {
                reviewPanel
            } else if let question {
                header(for: question)
                Text(question.question)
                    .frameFont(.emphasis)
                    // NOT what fixed the reported fault, and worth saying so: the
                    // clipping the operator hit was vertical, and `GatePanel`'s scroller is
                    // what addresses it. Measured both ways — an option's text
                    // wraps at a proposed width with or without this.
                    //
                    // Kept, but do not read it as a production guard: inside a
                    // vertical ScrollView the content is already proposed
                    // unbounded height, so in THIS hierarchy the modifier changes
                    // nothing. What it does change is the measurement path —
                    // `fittingSize` proposes unconstrained dimensions, where a
                    // bare Text reports a 1017pt single-line ideal width — so it
                    // is what lets the tests below measure height honestly.
                    // Defensive, cheap, and worth keeping only for that.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                    OptionCard(number: i + 1,
                               option: option,
                               multiSelect: question.multiSelect,
                               isTicked: ticked.contains(i + 1)) {
                        onChoose(i + 1, question.multiSelect)
                    }
                }

                // THE FREE-TEXT CARD, drawn only where the row was observed.
                //
                // The TUI appends `Type something.` after the model's options and
                // nothing in the payload mentions it, so this is the one affordance
                // here that exists purely because the mini reads the screen. Absent
                // means nobody established the row, NOT that the picker lacks one —
                // and the honest response to that is to draw nothing rather than
                // guess a digit, because the digit would answer a real option.
                //
                // ONE COMMIT PER QUESTION, WHICH IS WHY THE MULTISELECT CASE PUTS
                // THE FIELD ABOVE ITS BUTTON RATHER THAN GIVING IT ONE. Restoring
                // this card in #62 briefly drew two buttons that both committed —
                // the ticks button and the card's own — and nothing on screen said
                // which carried the typed text. The operator pressed one and asked
                // which they were meant to press, which is the whole finding: the
                // top button discarded what they had typed. The TUI itself draws a single commit
                // and treats its free-text row as another row above it, so the
                // second button was Deck inventing a distinction the picker does
                // not have.
                if question.multiSelect {
                    if let choiceCommit {
                        if let freeTextRow {
                            freeTextCard(row: freeTextRow, showsSend: false)
                        }
                        HStack(spacing: 8) {
                            // NAMED FOR WHAT IT DOES, because the two commits do
                            // different things and a button reading "Send answer"
                            // on question 1 of 3 would be a lie: nothing reaches
                            // the session until the review tab is submitted. The
                            // wording lives on the model so a test can hold it.
                            Button(SessionPaneModel.choiceCommitLabel(choiceCommit)) {
                                // The field is an input to this commit, not a
                                // separate act. With text, the answer has to go
                                // through the walk; without, the ticks alone do.
                                if SessionPaneModel.commitCarriesText(freeText) {
                                    onAnswerWithText()
                                } else {
                                    onSubmit()
                                }
                            }
                            .disabled(!SessionPaneModel.canCommitQuestion(
                                tickCount: ticked.count, freeText: freeText))
                            Text(SessionPaneModel.commitHint(
                                tickCount: ticked.count, freeText: freeText))
                                .frameFont(.body).foregroundStyle(.secondary)
                        }
                    } else {
                        // Said rather than hidden, and it still happens: with no
                        // reading of the TUI's button the pane cannot tell which
                        // question is on screen, and committing on that guess is
                        // what would answer a later question nobody chose. An
                        // unrecognised Claude Code version lands here.
                        // Ticks still register; only finishing needs the terminal.
                        //
                        // THE CARD GOES WITH THE BUTTON, because it no longer has
                        // one of its own: a field with no way to commit it is worse
                        // than no field, and this branch has nothing that can
                        // finish the question.
                        Text("Ticking works here, but finishing this answer has to "
                             + "be done in the terminal.")
                            .frameFont(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let freeTextRow {
                    // A single-select question draws no commit button of its own —
                    // a digit selects and confirms in one — so here the card keeps
                    // its button, and that button is the only way to send text.
                    freeTextCard(row: freeTextRow, showsSend: true)
                }
            }

            // The terminal is still here, and now it is the emergency exit it
            // was meant to be rather than the way a second question gets
            // answered at all.
            HStack(spacing: 8) {
                if gate.hasSuggestions {
                    // Named rather than offered. The "don't ask again" option
                    // writes a permission rule to settings, and a button that
                    // quietly changes what a session may do without asking is
                    // worse than one that is absent.
                    Text("A “don’t ask again” rule is offered here; take that in the terminal.")
                        .frameFont(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Open terminal", action: onFallBackToTerminal)
                    .frameFont(.body)
            }
        }
    }

    /// An answer in the user's own words, on the row the TUI appended for it.
    ///
    /// A CARD RATHER THAN A COMPOSER, because it is not a message. The composer
    /// sends to a listening session and the mini refuses that outright while one is
    /// blocked; this becomes the ANSWER. Drawn in the option list because that is
    /// where the TUI draws it — as row N+1, after the model's options — so the
    /// numbering the user sees matches the numbering the picker has.
    ///
    /// The row number is shown for the same reason the options show theirs: it is
    /// what the terminal would show, and a user switching between the two surfaces
    /// mid-question should not have to re-map them.
    /// `showsSend` is false on a multiselect, where the question's own commit button
    /// sends this field along with the ticks. See the call site for why there is
    /// only ever one commit per question.
    @ViewBuilder
    private func freeTextCard(row: Int, showsSend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row).").frameFont(.label).foregroundStyle(.secondary)
                // "Or" only where there are ticks to answer with instead. On a
                // single-select the options are taken by their own buttons and this
                // is not an alternative to anything on screen.
                Text(showsSend ? "Answer in your own words"
                               : "Or answer in your own words")
                    .frameFont(.emphasis)
            }
            HStack(spacing: 8) {
                TextField("Type an answer", text: $freeText)
                    .frameFont(.body)
                    .onSubmit(onAnswerWithText)
                if showsSend {
                    Button("Send", action: onAnswerWithText)
                        .frameFont(.body)
                        // Empty is not an answer, and committing one would resolve
                        // the question with nothing in it.
                        .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every question answered, the gate open on its review tab.
    ///
    /// The pane used to keep drawing the last question's cards here, at a picker
    /// that had moved on — so a click on what it labelled option 2 pressed
    /// `Cancel` and discarded every answer. This is that hazard's replacement.
    @ViewBuilder
    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ALL \(gate.questions.count) ANSWERED")
                .frameFont(.label).foregroundStyle(.secondary)
            // WORDED CAREFULLY, because the obvious phrasing is a lie. Every
            // answer WAS sent — a digit went to the picker as each question was
            // answered. What has not happened is the session receiving them: the
            // picker is holding them on its review tab. "Nothing has been sent
            // yet" said no action had been taken, which would leave a reader
            // wondering whether their clicks registered at all.
            Text("Your answers are held in the picker. The session receives them "
                 + "when you submit.")
                .frameFont(.emphasis)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Submit answers", action: onSubmitAnswers)
                // Cancel is deliberately absent: it discards every answer
                // already given, and the terminal is where a destructive choice
                // should be made with the review in front of you.
                Text("To change one, or to cancel, use the terminal.")
                    .frameFont(.body).foregroundStyle(.secondary)
            }
        }
    }

    /// The eyebrow above the question: its own header when it has one, and the
    /// position in the sequence when the gate carries more than one.
    @ViewBuilder
    private func header(for question: SessionState.Question) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if gate.questions.count > 1 {
                Text("Question \(questionIndex + 1) of \(gate.questions.count)".uppercased())
                    .frameFont(.label).foregroundStyle(.secondary)
            } else if let header = question.header {
                Text(header.uppercased())
                    .frameFont(.label).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if questionsRemaining > 0 {
                // Said plainly, because the pane is now promising to ask them.
                Text("\(questionsRemaining) more after this")
                    .frameFont(.body).foregroundStyle(.tertiary)
            }
        }
    }

}

/// One option, as a card that grows to fit its own text.
///
/// THE CARD IS THE HIT TARGET. The old row put the click on a number and let
/// the description trail off the edge of the pane, which is the shape the
/// operator reported: "the text runs out of the box and there's no way to see it." The
/// description is the reason to prefer one option over another, so it gets as
/// many lines as it needs.
///
/// The number stays visible because the number is what Deck sends. Keeping it
/// on screen is what lets a reader check that the pane and the session agree
/// about which option was taken.
///
/// Internal rather than private so `PickerLayoutTests` can host it and measure
/// that a long description makes the card taller instead of disappearing off
/// its edge. That is the fault this type exists to fix, and the only way to
/// hold it fixed is to measure it.
struct OptionCard: View {
    let number: Int
    let option: SessionState.Option
    let multiSelect: Bool
    let isTicked: Bool
    var onTake: () -> Void

    /// ⌘1–9 selects the matching option (the operator, 2026-09-05: "sure why not,
    /// seems good" — `design/redesign/05-states.html`'s gate frame draws the
    /// badge). nil past nine, where `SessionAgent` refuses the choice — see
    /// the doc on `number` at the call site in `GateView`, which is what
    /// keeps a tenth card from ever reaching here with a shortcut it cannot
    /// send.
    ///
    /// BOUND TO THE OPTION'S OWN POSITION, NOT ITS LABEL. `number` is the
    /// same value the card prints and the same one `onChoose` sends, so a
    /// reader who presses ⌘3 gets exactly the option reading "3" — there is
    /// no second source that could disagree with it.
    ///
    /// A pure function, tested without hosting a view: SwiftUI's shortcut
    /// wiring itself is not something an `NSHostingView` pass can assert on
    /// (see `ComposerView`'s doc on its own `.keyboardShortcut`), but which
    /// digit maps to which option is ordinary logic and is asserted here.
    nonisolated static func shortcutKey(for number: Int) -> KeyEquivalent? {
        guard (1...9).contains(number) else { return nil }
        return KeyEquivalent(Character("\(number)"))
    }

    var body: some View {
        let button = Button(action: onTake) {
            HStack(alignment: .top, spacing: 8) {
                if multiSelect {
                    // The tick is Deck's record of the digit it sent, since the
                    // gate never reports what is already chosen.
                    Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isTicked ? Color.accentColor : .secondary)
                }
                Text("\(number)")
                    .frameFont(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail = option.detail {
                        Text(detail)
                            .frameFont(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // The visible badge beside the shortcut it names — drawn as
                // `05-states.html`'s gate frame draws it, so a reader can see
                // ⌘3 is available without having to try it.
                if let key = OptionCard.shortcutKey(for: number) {
                    Text("⌘\(String(key.character))")
                        .frameFont(.body)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isTicked ? Color.accentColor.opacity(0.08) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isTicked ? Color.accentColor.opacity(0.55)
                                           : Color.secondary.opacity(0.25),
                                  lineWidth: isTicked ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.detail.map { "\(option.label). \($0)" } ?? option.label)

        // THE GATE'S OWN LIFETIME IS THE SCOPE. `OptionCard` exists in the
        // view tree only while `SessionPaneView.composer` is drawing
        // `GatePanel` in place of the ordinary composer — see that
        // `@ViewBuilder` — so the shortcut is torn down along with the card
        // the moment the gate clears, the same way any other SwiftUI view's
        // modifiers go away when the view is removed. There is no separate
        // flag to thread here for "the gate is showing": that condition
        // already governs whether this type is instantiated at all.
        if let key = OptionCard.shortcutKey(for: number) {
            button.keyboardShortcut(key, modifiers: .command)
        } else {
            button
        }
    }
}

/// The composer: the message box and, beneath it, a full-width control bar —
/// Commands and the held-queue chip on the left, one fixed-width primary slot
/// on the right, and Interrupt as its own bordered button in the bar's
/// flexible middle while a turn runs (`design/input-pane-redesign.md`, Option
/// A, second pass, 2026-08-31). The bar replaces the old right-hand control
/// column, which resized with state and narrowed the box as buttons came and
/// went; the box now takes the pane's full width and holds still.
///
/// THE SLOT NEVER SHOWS INTERRUPT. The first pass merged Send and Interrupt
/// into one slot on the claim that they are mutually exclusive in the model;
/// they are not (see `isWorking`'s doc comment below), so the slot always
/// holds the safe action — Send, or Replace when the box holds a pulled
/// queue — and Interrupt is a separate control that appears and disappears
/// with the working phase without moving anything already drawn.
///
/// Not `private`, matching `PaneStatusBar` and `GatePanel`: so a test can
/// host it in an `NSHostingView` with a fixture no live session ever produces
/// and confirm every state draws without crashing. That is NOT the same
/// claim as "the layout holds still" — the property Option A actually
/// promises is a pixel position in rendered SwiftUI output, which no XCTest
/// in this repo can pin (see the PR body; #153 was reverted the same day
/// this shipped for exactly that gap, one layer over).
struct ComposerView: View {
    @Binding var text: String
    let enabled: Bool
    let sendKey: SendKeyPreference
    /// The frame tint, so the input box carries the same colour as the strip it
    /// sits in rather than the editor's default white or dark fill — the box is
    /// one of the frame elements the operator asked to match the canvas.
    var tint: Color?
    /// The destructive ink Interrupt borders and reads in — see
    /// `SessionPaneView.errorInk`. Passed rather than solved here, the same
    /// reason `tint` is: it depends on the canvas and appearance, neither of
    /// which this view can see.
    let errorInk: Color
    /// The crew's own hue, solved as a filled slab's background under white
    /// text — see `SessionPaneView.progressFillInk`. Passed rather than
    /// solved here, the same reason `errorInk` is: it depends on the
    /// session's accent and appearance, neither of which this view can see.
    let progressFillInk: Color
    var onSend: () -> Void
    /// Whether a turn is in flight. Gates the separate Interrupt button's
    /// presence — see `interruptButton` — and nothing else: `canSend` never
    /// reads this, because `Phase.working.acceptsMessage` is `true` (the
    /// held-queue mechanism — sending while working queues the message
    /// rather than being refused), so the primary slot's own style and label
    /// stay whatever `canSend` and `isRewrite` already say regardless of
    /// whether a turn is running.
    var isWorking: Bool = false
    var onInterrupt: () -> Void = {}

    /// How many messages the session is holding, or nil/unknown — see
    /// `SessionState.HeldCount`. Drives the held-queue chip's visibility and
    /// text and, together with `text`, `SessionPaneModel.rewriteTriggers` —
    /// the same predicate the up-arrow handler below consults.
    var heldCount: SessionState.HeldCount?
    var onRewrite: () -> Void = {}
    /// Whether the composer's content came out of the queue rather than
    /// being typed fresh — flips the chip to "editing N held" and the
    /// primary slot's label to "Replace". See `SessionPaneModel.isRewrite`.
    var isRewrite: Bool = false

    /// What the session can be told to do by name, or nil until someone opens
    /// the menu. See `CommandsMenu`.
    let commands: SessionCommands?
    let commandsError: String?
    let loadingCommands: Bool
    /// Opening the menu is what fetches; it is one ssh round trip and it does
    /// not change on its own.
    let onOpenCommands: () -> Void
    /// Picking one puts it in the box rather than sending it, because a slash
    /// command usually takes an argument and sending a bare one would be a
    /// guess about what the reader meant.
    let onPickCommand: (String) -> Void

    /// The composer's own size, independent of the chrome around it. You compose
    /// prose here, so it takes macOS's body size rather than the glance size the
    /// vitals and buttons use.
    ///
    /// NO DEFAULT, DELIBERATELY. It had one, and the call site never passed it —
    /// so the settings slider wrote a value that nothing read, and the box stayed
    /// 13pt however far it moved. The operator found it by restarting and trying. A
    /// defaulted parameter on a single-call-site view buys nothing and hides
    /// exactly this: without one, forgetting to wire it is a compile error.
    let typography: ComposerTypography

    /// Whether the box has keyboard focus, which is what the outline draws.
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the composer may pull the queue back right now — the same
    /// predicate the up-arrow gesture and the button's enabled state both
    /// consult, so a disabled button and a key that falls through to the
    /// editor always agree on why.
    private var canRewrite: Bool {
        enabled && SessionPaneModel.rewriteTriggers(draft: text, held: heldCount)
    }

    /// How many messages are held, for the chip's visibility — shown
    /// whenever something is waiting, even while the composer holds unsent
    /// text and the chip is disabled, so the affordance stays discoverable
    /// rather than appearing and disappearing as the reader types.
    private var heldMessageCount: Int? {
        if case .count(let n) = heldCount { return n }
        return nil
    }

    /// The box's outline. Held as a plain `Color` rather than inlined: mixing a
    /// `ShapeStyle` and a `Color` across a ternary inside the view builder made
    /// the expression too much for the type checker, which fails as a timeout
    /// several lines away from the cause.
    private var outlineColour: Color {
        isFocused ? Color.accentColor : Color.secondary.opacity(0.25)
    }

    /// What the primary slot draws — the one control Send and Replace share.
    /// Interrupt is never among these: it is a separate control (see
    /// `interruptButton`) so this slot only ever needs a safe style, and no
    /// transition between its two cases needs guarding.
    enum PrimaryStyle: Equatable {
        /// Filled accent slab, enabled. Send or Replace, per `isRewrite`.
        case actionable
        /// Filled but dimmed slab, disabled — never the flat pale label
        /// Send used to draw when idle. `.disabled(true)` still applies to
        /// the button carrying this style, so VoiceOver reads it as
        /// "dimmed" rather than the control vanishing.
        case disabled
    }

    /// Which style the slot takes. `isWorking` never enters this: the epic's
    /// first pass claimed Send and Interrupt were mutually exclusive in the
    /// model ("Send is disabled exactly while the session is working"), and
    /// that is false — `canSend` never reads `isWorking`, and
    /// `Phase.working.acceptsMessage` is `true` (the held-queue mechanism:
    /// sending while working queues the message rather than refusing it). So
    /// the slot stays whatever `canSend` already says, working turn or not,
    /// and Interrupt draws as its own control alongside it instead of
    /// replacing it.
    nonisolated static func primaryStyle(canSend: Bool) -> PrimaryStyle {
        canSend ? .actionable : .disabled
    }

    /// The slot's own label, key included — "Send ↩" / "Send ⌘↩" / "Replace
    /// ↩" / "Replace ⌘↩". Never "Interrupt" — the slot doesn't carry that
    /// state; see `interruptButton`.
    nonisolated static func primaryLabel(isRewrite: Bool, sendKey: SendKeyPreference) -> String {
        let key = sendKey.sendsOnBareReturn ? "↩" : "⌘↩"
        return "\(isRewrite ? "Replace" : "Send") \(key)"
    }

    nonisolated static func primaryAccessibilityLabel(isRewrite: Bool) -> String {
        isRewrite ? "Replace held messages" : "Send message"
    }

    /// The separate Interrupt button's accessibility label — distinct from
    /// `primaryAccessibilityLabel` because the two are now distinct controls
    /// rather than one slot narrating whichever state it currently shows.
    static let interruptAccessibilityLabel = "Interrupt the running turn"

    /// The held-queue chip's text — "↑ N held" normally, "editing N held"
    /// once Rewrite has pulled the queue into the box, so the primary
    /// slot's own rename to "Replace" reads as the pane announcing a mode
    /// rather than a button quietly relabelling itself.
    nonisolated static func rewriteChipText(heldCount: Int, isRewrite: Bool) -> String {
        isRewrite ? "editing \(heldCount) held" : "↑ \(heldCount) held"
    }

    nonisolated static func rewriteChipAccessibilityLabel(heldCount: Int) -> String {
        "\(heldCount) message\(heldCount == 1 ? "" : "s") held — pull back to edit"
    }

    /// The caption's one remaining fact once the send key moves onto the
    /// primary slot's own face.
    nonisolated static func newlineHint(_ sendKey: SendKeyPreference) -> String {
        sendKey.sendsOnBareReturn ? "⇧↩ new line" : "↩ new line"
    }

    private var primaryStyleValue: PrimaryStyle {
        ComposerView.primaryStyle(canSend: canSend)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: $text)
                .font(.system(size: typography.clampedFontSize))
                // 90pt was about four lines, and a prompt driving an agent is
                // routinely longer than that — the box became a scroller for the
                // thing you were still writing. It grows to roughly ten lines
                // before scrolling now, and still starts at one.
                .frame(minHeight: 28, maxHeight: 160)
                // Full pane width — the box no longer shares its row with a
                // control column, so nothing narrows it.
                .frame(maxWidth: .infinity)
                .disabled(!enabled)
                .focused($isFocused)
                // The editor paints its own opaque fill; hiding it lets the tint
                // behind show, so the box matches the strip instead of sitting on
                // it as a white rectangle. A soft rounded outline keeps it legible
                // as an input once the fill no longer distinguishes it.
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 5).fill(tint ?? Color.clear))
                // THE OUTLINE IS THE ONLY FOCUS SIGNAL LEFT, which is why it
                // answers to focus. Tinting the fill to match the strip was
                // deliberate, but it took the box's last unfocused/focused
                // difference with it: nothing on screen said whether the next
                // keystroke would land here. The tint is the row's own accent,
                // so the box agrees with the frame around it rather than with
                // the system's blue.
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(outlineColour, lineWidth: isFocused ? 2 : 1))
                // Return is intercepted BEFORE the editor sees it, which is the
                // only way a TextEditor can send on Return: by the time the
                // newline is in the text, removing it again is a race with the
                // user's next keystroke. `.handled` swallows the key, `.ignored`
                // lets the editor insert its newline as usual.
                //
                // Shift-Return is not listed and does not need to be: an
                // unmatched modifier combination falls through to the editor,
                // which is exactly the newline the preference promises.
                .onKeyPress(.return, phases: .down) { press in
                    guard sendKey.sendsOnBareReturn,
                          press.modifiers.isEmpty else { return .ignored }
                    // A blank composer swallows the key rather than sending
                    // nothing: Return in an empty message box should not insert
                    // a newline the user then has to delete.
                    if canSend { onSend() }
                    return .handled
                }
                // `.ignored` IS LOAD-BEARING HERE. Up-arrow in a non-empty
                // composer is what moves the cursor in a text editor, and
                // stealing it would break editing a multi-line message — so
                // this only takes the key when `canRewrite` says the
                // composer is empty and something is actually waiting.
                // Modifiers fall through too: Option/Shift-Up are the
                // editor's own selection and jump gestures.
                .onKeyPress(.upArrow, phases: .down) { press in
                    guard SessionPaneModel.upArrowTakesTheKey(modifiers: press.modifiers,
                                                             canRewrite: canRewrite)
                    else { return .ignored }
                    onRewrite()
                    return .handled
                }
            HStack(spacing: 8) {
                // Quiet end of the bar: borderless, secondary ink. An SF
                // Symbol, like every icon in this bar: a raw codepoint would
                // ignore the text-scale preference.
                CommandsMenu(commands: commands,
                             error: commandsError,
                             loading: loadingCommands,
                             onOpen: onOpenCommands,
                             onPick: onPickCommand)
                if let heldMessageCount, heldMessageCount > 0 {
                    rewriteChip(heldMessageCount)
                }
                // The bar's one flexible region. Commands and the held chip
                // grow it from the left; Interrupt, the hint and the primary
                // slot hold the right side fixed, so Interrupt grows IN from
                // this space instead of displacing anything already drawn.
                Spacer(minLength: 8)
                if isWorking {
                    interruptButton
                }
                // A deliberate buffer: it sits between Interrupt and the
                // primary slot so a click drifting left of Send lands on
                // dead text, not on the stop button beside it.
                Text(ComposerView.newlineHint(sendKey))
                    .frameFont(.caption)
                    .foregroundStyle(.tertiary)
                primarySlot
            }
            .frame(maxWidth: .infinity)
        }
    }

    // Left of the Spacer, so it grows rightward into empty space and leaves
    // the primary slot — the thing the hand targets — pixel-identical
    // whether or not it is present.
    @ViewBuilder
    private func rewriteChip(_ heldMessageCount: Int) -> some View {
        Button(action: onRewrite) {
            Text(ComposerView.rewriteChipText(heldCount: heldMessageCount, isRewrite: isRewrite))
                .frameFont(.caption)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(isRewrite ? Color.accentColor.opacity(0.12)
                                     : Color.secondary.opacity(0.12)))
        .overlay(
            Capsule().strokeBorder(isRewrite ? Color.accentColor.opacity(0.55)
                                             : Color.secondary.opacity(0.3),
                                    lineWidth: 1))
        .foregroundStyle(isRewrite ? Color.accentColor : Color.secondary)
        .disabled(!canRewrite)
        .help(canRewrite
              ? "Pull \(heldMessageCount == 1 ? "the waiting message" : "\(heldMessageCount) waiting messages") back into this box for editing."
              : "Clear this box first — Rewrite replaces what's here.")
        .accessibilityLabel(ComposerView.rewriteChipAccessibilityLabel(heldCount: heldMessageCount))
    }

    /// The fixed-width slot Send and Replace share. Never Interrupt — see
    /// the type-level doc comment on `PrimaryStyle`.
    ///
    /// Carries `.keyboardShortcut(.return, modifiers: .command)` directly,
    /// unconditional on `sendKey`, so ⌘↩ stays bound under both preferences
    /// exactly as before. A separate hidden carrier button used to hold this
    /// shortcut, because attaching it here would have retargeted Command-
    /// Return to `onInterrupt` the instant the slot morphed into Interrupt.
    /// That risk is gone now that the slot never shows Interrupt, so the
    /// carrier was deleted rather than kept as unexplained dead weight.
    private var primarySlot: some View {
        let style = primaryStyleValue
        return Button(action: onSend) {
            ZStack {
                // Invisible sizers at every label this slot can ever show, so
                // its width comes from the widest one and a Send/Replace
                // morph never reflows the bar. A ZStack sizes to its largest
                // child, which tracks the text-scale preference instead of
                // freezing a pixel number that would clip at a larger
                // setting.
                Group {
                    ForEach(SendKeyPreference.allCases, id: \.rawValue) { key in
                        Text(ComposerView.primaryLabel(isRewrite: false, sendKey: key))
                        Text(ComposerView.primaryLabel(isRewrite: true, sendKey: key))
                    }
                }
                .opacity(0)
                .accessibilityHidden(true)

                Text(ComposerView.primaryLabel(isRewrite: isRewrite, sendKey: sendKey))
            }
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .background(primaryBackground(style))
        .foregroundStyle(primaryForeground(style))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // The disabled slab exposes `isEnabled == false` via `.disabled`
        // rather than merely dimming its own colours, so VoiceOver says
        // "dimmed" instead of the control silently vanishing from the tree.
        .disabled(style == .disabled)
        .accessibilityLabel(ComposerView.primaryAccessibilityLabel(isRewrite: isRewrite))
    }

    /// The bordered destructive button beside the slot, present exactly
    /// while a turn runs. It is its own control rather than a slot state —
    /// see the type-level doc comment on `ComposerView` — so it never
    /// occupies the position the hand knows as Send.
    private var interruptButton: some View {
        Button(action: onInterrupt) {
            Label("Interrupt", systemImage: "stop.fill")
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(errorInk)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(errorInk.opacity(0.55), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // CARRIED OVER FROM THE PRE-REDESIGN BUTTON, not written fresh. This is
        // the one control in the bar whose click cannot be taken back, and the
        // tooltip is where a mouse user learns that the draft is not lost —
        // the layout already spends a hint-as-buffer on not being clicked by
        // accident, so telling a hesitating reader what it does belongs with it.
        .help("Stop the in-flight response. The agent stays, "
              + "and the message it was working on returns to this box.")
        .accessibilityLabel(ComposerView.interruptAccessibilityLabel)
    }

    @ViewBuilder
    private func primaryBackground(_ style: PrimaryStyle) -> some View {
        switch style {
        case .actionable: RoundedRectangle(cornerRadius: 6).fill(progressFillInk)
        case .disabled: RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.18))
        }
    }

    private func primaryForeground(_ style: PrimaryStyle) -> Color {
        switch style {
        case .actionable: return .white
        case .disabled: return .secondary
        }
    }
}

extension SessionState {
    /// What a session's dot draws.
    ///
    /// ONE OBJECT PER ROW, WHICH IS THE WHOLE POINT. Every version before this
    /// put state in a SECOND mark trailing the row, beside the identity dot
    /// leading it — a severity ramp first, then a needs-you badge, then a
    /// two-axis vocabulary of arcs and rings. Each was more correct than the
    /// last and all of them shared the defect the operator named: "there's just too much
    /// clutter and it doesn't mean anything." Two marks per row is two things to
    /// read where the row has one thing to say.
    ///
    /// So the identity dot IS the state. It already leads every row, it is
    /// already the session's own colour, and it was already the thing the eye
    /// lands on. Now its SHAPE says what the session is doing and its MOTION
    /// says whether that is still happening. Nothing trails the row at all.
    ///
    /// | Mark | Shape | Motion |
    /// |---|---|---|
    /// | `.ready` | square | still |
    /// | `.busy` | gapped disc | spins |
    /// | `.listening` | circle | pulses |
    /// | `.needsYou` | right-pointing triangle | still |
    /// | `.unreadable` | hollow ring | still |
    ///
    /// COLOUR IS THE SESSION'S OWN, WITH ONE EXCEPTION. `.needsYou` drops the
    /// accent for the attention ink, because that is the state the whole rail is
    /// scanned for and shape alone is a weak signal at eight points across
    /// fifteen rows. Exactly one colour in the rail is not somebody's identity,
    /// and it is the one you are looking for.
    ///
    /// A FUNCTION OF THE WHOLE STATE, NOT JUST THE PHASE, which is why this is
    /// not on `Phase`. `.listening` and `.ready` are the same phase — a co at
    /// its prompt — and `liveAgents` is the only thing that separates them.
    enum Mark: Equatable {
        /// Stopped, and waiting on you. A right-pointing triangle, in the
        /// attention ink: the arrow points at the move you make, and it is the
        /// only dot in the rail that is not a session's colour. `gateAge` is how
        /// long it has been standing, in seconds, feeding
        /// `ThemeRecipe.staleness`; nil when the mini could not date it, which
        /// reads as fresh.
        case needsYou(gateAge: Double?)
        /// co is mid-turn. A gapped disc, turning.
        ///
        /// GAPPED BECAUSE IT TURNS. A circle rotating is indistinguishable from
        /// a circle standing still, so the shape that spins is the one that has
        /// to carry a notch — the same constraint that shaped the arc this
        /// replaces.
        case busy
        /// co is at its prompt with dispatched agents alive behind it. A full
        /// circle, breathing. Open to you: this is the state where redirecting
        /// the work is both possible and often the point.
        case listening
        /// Ready. A square — at rest, parked, nothing in flight. The dot is
        /// still the session's colour, so the row still says which session it
        /// is (the operator: "we can see the session is alive from the rail type and
        /// color").
        case ready
        /// The mini could not establish what this session is doing. A hollow
        /// ring, because a filled shape would assert something.
        ///
        /// DISTINCT FROM `.ready`, and it was not before. Drawing "unknown" as
        /// the settled square would claim a session is done when the honest
        /// answer is that nobody knows — and the pane's answer to unknown is to
        /// offer the raw terminal, which is not what a settled row invites.
        case unreadable
        /// Not polled yet. A plain circle: alive-looking, claiming nothing.
        ///
        /// Not produced by `mark` — the rail's model returns it for a session it
        /// has no reading for. A row starts here for one poll interval rather
        /// than asserting `.ready`, which would say "done" about a session that
        /// might be mid-turn.
        case unpolled
    }

    /// Whether an agent is dispatched and alive behind this session — the
    /// one fact `.listening` turns on. Reads the richer `agentRuns` when the
    /// mini reports it, `liveAgents` otherwise, the same two-shape fallback
    /// `liveAgents` itself already performs one level down (top-level
    /// `agents` over `vitals.agents`) for a mini that predates each field.
    /// One decode, two consumers (this mark, and the crew-stats panel), so
    /// the two cannot read the wire differently.
    var hasDispatchedAgents: Bool {
        if let agentRuns { return !agentRuns.isEmpty }
        return !liveAgents.isEmpty
    }

    var mark: Mark {
        switch phase {
        // The one dot that leaves the session's palette. `waiting` used to share
        // this ink, on the reasoning that both meant "go there" — but a co at
        // its prompt is not asking for anything, and spending the attention
        // colour on the common case is what made the rare one hard to find.
        case .blocked:
            return .needsYou(gateAge: lastEventAge)
        case .working:
            return .busy
        // IDLE AND WAITING ARE ONE HUMAN STATE. On the wire they are a `Stop`
        // hook and Claude Code's sixty-second idle notification: the same co,
        // at the same prompt, differing only in whether a minute has passed.
        // Drawing them differently put a mark on a row where nothing had
        // changed, and left a genuinely ready row blank for its first minute.
        case .idle, .waiting:
            return hasDispatchedAgents ? .listening : .ready
        // A session that has ended is at rest, and the row greys besides. A
        // session nobody can read is not at rest; it is unread.
        case .ended:
            return .ready
        case .unknown:
            return .unreadable
        }
    }
}

/// The composer's list of what this session can be told to do by name.
///
/// WHY A MENU AND NOT A HINT WHILE TYPING. Autocomplete answers "finish this
/// word"; the question here is "did my commands load at all", which you ask
/// BEFORE typing anything. A list you can open on an empty box answers it; a
/// completion that appears after `/` does not, because a `/` that offers
/// nothing is exactly as ambiguous as the silence it replaced.
///
/// Not `private`, so a test can host it with fixtures no live session
/// produces — the empty cases especially, which are the ones that have to say
/// something useful rather than showing a blank menu.
struct CommandsMenu: View {
    let commands: SessionCommands?
    let error: String?
    let loading: Bool
    let onOpen: () -> Void
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            if loading {
                Text("Reading the session's commands…")
            } else if let error {
                // The failure is stated, not swallowed. A menu that shows
                // nothing when the read failed looks exactly like a session
                // with no commands, which is the confusion this feature is for.
                Text("Could not read them: \(error)")
                Button("Try again", action: onOpen)
            } else if let commands {
                if commands.entries.isEmpty {
                    Text(commands.emptyExplanation ?? "Nothing to invoke.")
                } else {
                    entries(commands)
                }
                Divider()
                // A BUTTON INSIDE THE MENU DOES FIRE, which is the difference
                // between this and the gesture that used to wrap the whole
                // control. It is how a file added since the session started
                // gets picked up without restarting anything.
                Button("Reload", action: onOpen)
            } else {
                // Reached only before the first read has landed — the pane
                // starts one — so this is a beat, not a resting state.
                Text("Reading the session's commands…")
            }
        } label: {
            // `terminal` — a command prompt, the place commands are typed —
            // rather than `slash.circle`, which reads as the prohibited
            // mark next to a menu that works. Every slash-in-a-circle
            // variant was rejected for the same reason
            // (design/input-pane-redesign.md).
            Label("Commands", systemImage: "terminal")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Quiet end of the bar — secondary ink, where a menu belongs.
        .foregroundStyle(.secondary)
        .help("What this session can be told to do by name.")
    }

    /// Project entries above user-wide ones, under headings, in the order the
    /// mini already sorted them. The scopes answer different questions — "did
    /// THIS repo's commands load" versus "what do I always have" — and running
    /// them together makes the first one hard to read.
    @ViewBuilder
    private func entries(_ commands: SessionCommands) -> some View {
        ForEach(SessionCommands.Entry.Scope.ordered, id: \.rawValue) { scope in
            let inScope = commands.entries.filter { $0.scope == scope }
            if !inScope.isEmpty {
                Section(scope.heading) {
                    ForEach(inScope) { entry in
                        Button {
                            onPick(entry.slash)
                        } label: {
                            Text(entry.slash)
                            // A menu item's second line is its help text on
                            // macOS; the description is what makes 24 skills
                            // readable rather than a wall of names.
                            if let description = entry.description {
                                Text(description)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension SessionCommands.Entry.Scope {
    /// Project first: the question is almost always about this repo.
    static var ordered: [Self] { [.project, .user] }

    var heading: String {
        switch self {
        case .project: return "This project"
        case .user: return "All projects"
        }
    }
}
