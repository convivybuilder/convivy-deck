import SwiftUI

/// Deck's settings window, reached by Cmd-, like every other Mac app.
///
/// WHY THIS EXISTS. Every preference Deck has was reachable only by
/// hand-editing `~/.config/convivy/deck/theme.json`, or by a control tucked
/// into the surface it affected — the theme picker in a rail row's context
/// menu, font size behind Cmd-+. That was defensible while there were two
/// preferences. It stops being defensible the moment a user has to be TOLD
/// where a setting lives, and it fails completely for a user who does not know
/// the file exists.
///
/// The file remains the persistence layer and the escape hatch. This is the
/// interface, and the rule it follows is the one the theme picker established:
/// a config file is storage, never how a person changes a setting.
///
/// Session colors are deliberately absent. They belong to a session, they are
/// already picked from that session's own row, and reproducing the whole rail
/// here would be a worse version of a control that works.
struct SettingsView: View {
    @EnvironmentObject private var store: ThemeStore
    @EnvironmentObject private var navigation: SettingsNavigation

    /// Injected so a test can hand the General tab a notice, or none, without a
    /// bundle built by `make-app.sh` anywhere near it.
    var licence: LicenceNotice = .bundled

    /// The General tab's floor, in points: the natural height of its form with
    /// the licence notice showing. See the comment on the frame that uses it.
    ///
    /// Raised from 336 when the appearance option became "Builder Default". The
    /// cause is the Appearance picker's layout, not the label's height: an inline
    /// picker draws its options in one row beside its label while they fit, and
    /// stacks them into four rows once they do not. "Split" fit that row at the
    /// form's ideal width of 496pt, so the form measured 336; "Builder Default"
    /// does not, so the form measures 427, which is the 91pt difference between
    /// one row and four. The stacked list is the content now, so the floor is
    /// that height. `SettingsLicenceNoticeTests` holds it to the measured form.
    static let generalMinimumHeight: CGFloat = 427

    /// Injected, like `licence`, so a test can measure the form's natural height
    /// with the floor taken away. A hosted view reports the LARGER of its natural
    /// height and its floor, so a floor left above the natural height reads as
    /// the natural height and a stale floor cannot be seen from outside.
    var generalFloor: CGFloat = SettingsView.generalMinimumHeight

    private var configuration: ThemeConfiguration { store.configuration }

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            general.tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsNavigation.Tab.general)
            text.tabItem { Label("Text", systemImage: "textformat.size") }
                .tag(SettingsNavigation.Tab.text)
            SessionsSettingsView()
                .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
                .tag(SettingsNavigation.Tab.sessions)
            HostsSettingsView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
                .tag(SettingsNavigation.Tab.hosts)
            SigningKeySettingsView()
                .tabItem { Label("Signing", systemImage: "touchid") }
                .tag(SettingsNavigation.Tab.signing)
        }
        // A floor, not a fixed width. `width: 460` pinned every tab and left the
        // window with no resizable axis, which is survivable for a tab of
        // sliders and not for the Sessions list, whose length is the user's.
        .frame(minWidth: 460)
        .padding(.top, 8)
        // The window draws the chrome's pin, so it matches the header above the main
        // pane. The window's own appearance reaches the title bar and the tab strip,
        // which AppKit draws and a SwiftUI colour scheme does not reach.
        .surfaceAppearance(configuration.pinnedSurface(for: .chrome))
        .background(WindowAppearance(appearance: configuration.pinnedAppearance(for: .chrome)))
    }

    private var general: some View {
        Form {
            Picker("Sending a message:", selection: sendKey) {
                ForEach(SendKeyPreference.allCases, id: \.self) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.radioGroup)

            Divider()

            Picker("Appearance:", selection: appearance) {
                Text("Follow the system").tag(ThemeConfiguration.AppearancePreference.system)
                Text("Light").tag(ThemeConfiguration.AppearancePreference.light)
                Text("Dark").tag(ThemeConfiguration.AppearancePreference.dark)
                Text("Builder Default")
                    .tag(ThemeConfiguration.AppearancePreference.builderDefault)
            }
            .pickerStyle(.inline)

            Divider()

            Text(AppVersionInfo.displayString(from: Bundle.main))
                .font(.caption).foregroundStyle(.secondary)

            LicenceNoticeSection(licence: licence)
        }
        .formStyle(.grouped)
        // A floor, not a fixed height, for the reason `minWidth` above is one.
        // `height: 340` was measured against six rows in 47ab8c6; e86e7d3 then
        // rewrapped the crews-root caption from one line to two and left the
        // number alone. A grouped Form is List-backed, so outgrowing a pinned
        // height scrolls rather than clips — which hides the LAST row first,
        // and the last rows are the version and the licence notice. A floor lets
        // the tab grow instead, so the next line added here does not silently
        // push them out of sight.
        //
        // THE NUMBER WAS STALE BEFORE THE NOTICE ARRIVED. Measured with the
        // notice added, the form's natural height was 454pt; without it, 390pt,
        // already 50pt over the old 340. Nothing scrolled only because the window
        // opens at its natural size. A window the user drags shorter than that
        // would have scrolled the version away, so the floor is the natural
        // height itself, and `SettingsLicenceNoticeTests` fails when a change
        // outgrows it or leaves it standing above it. It is 427pt with the
        // Builder Default option stacked, because the Appearance picker stacks its
        // four options once they stop fitting in one row beside the label.
        .frame(minHeight: generalFloor)
    }

    /// Four surfaces, each sized on its own.
    ///
    /// GROUPED BY SURFACE RATHER THAN BY PROPERTY, so the question a user
    /// arrives with — "the conversation is too small" — is answered by one
    /// section rather than by finding the size slider and then, elsewhere, the
    /// spacing one. The tab is "Text" and not "Terminal" because the terminal is
    /// now one of four things it governs.
    private var text: some View {
        Form {
            Section("Conversation") {
                slider("Size:", value: sessionScale,
                       range: SessionTypography.minimumScale...SessionTypography.maximumScale,
                       step: 0.05,
                       readout: "\(Int(configuration.sessionTypography.clampedScale * 100))%")
                // A percentage is honest about what the renderer takes, and
                // meaningless on its own — the caption is what makes it legible.
                Text("≈ \(Int(configuration.sessionTypography.effectiveProsePixels.rounded())) px prose")
                    .font(.caption).foregroundStyle(.secondary)

                slider("Line spacing:", value: sessionLineHeight,
                       range: SessionTypography.minimumLineHeight...SessionTypography.maximumLineHeight,
                       step: 0.05,
                       readout: String(format: "%.2f", configuration.sessionTypography.clampedLineHeight))
            }

            Section("Message box") {
                slider("Size:", value: composerSize,
                       range: Double(ComposerTypography.minimumFontSize)...Double(ComposerTypography.maximumFontSize),
                       step: 0.5,
                       readout: String(format: "%.1f", configuration.composerTypography.clampedFontSize))
            }

            Section("Frame") {
                slider("Size:", value: frameSize,
                       range: Double(FrameTypography.minimumBaseSize)...Double(FrameTypography.maximumBaseSize),
                       step: 0.5,
                       readout: String(format: "%.1f", configuration.frameTypography.clampedBaseSize))
                Text("Rail rows, status text, buttons and labels. Everything scales together.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Terminal") {
                slider("Size:", value: fontSize,
                       range: Double(TerminalTypography.minimumFontSize)...Double(TerminalTypography.maximumFontSize),
                       step: 0.5,
                       readout: String(format: "%.1f", configuration.typography.clampedFontSize))
                // The step function is invisible and surprising, and a user who
                // widens their columns by half a point deserves to know why.
                Text("Column width snaps at certain sizes.")
                    .font(.caption).foregroundStyle(.secondary)

                slider("Line spacing:", value: lineSpacing,
                       range: Double(TerminalTypography.minimumLineSpacing)...Double(TerminalTypography.maximumLineSpacing),
                       step: 0.05,
                       readout: String(format: "%.2f", configuration.typography.clampedLineSpacing))

                // The font itself stays file-only for now. Offering a font
                // picker means offering fonts that render a terminal badly, and
                // the fallback for an unresolvable name is already handled where
                // it belongs.
                if configuration.typography.fontNameIsUnresolvable {
                    Label("\(configuration.typography.fontName ?? "The configured font") is not installed; "
                          + "the system monospaced font is being used.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }

    /// One slider row. Extracted because there are now six of them and the
    /// readout column has to line up across every section — a per-row `frame`
    /// repeated six times is how that stops being true.
    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double,
                        readout: String) -> some View {
        LabeledContent(label) {
            HStack {
                // `onEditingChanged` keeps a drag from writing the config on
                // every tick: the binding previews in memory, and the file is
                // written once, when the drag ends.
                Slider(value: value, in: range, step: step,
                       onEditingChanged: persistWhenDragEnds)
                Text(readout).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: - Bindings
    //
    // Each writes through the store rather than mutating a local copy, so a
    // change lands in the file and in every view at once. The store is the
    // single source of truth; these are only the shape SwiftUI's controls want.

    private var sendKey: Binding<SendKeyPreference> {
        Binding(get: { configuration.sendKey }, set: { store.setSendKey($0) })
    }

    private var appearance: Binding<ThemeConfiguration.AppearancePreference> {
        Binding(get: { configuration.appearancePreference },
                set: { store.setAppearancePreference($0) })
    }

    /// SwiftUI calls this with `true` when a drag starts and `false` when it
    /// ends. A click that jumps the slider without dragging sends the same
    /// pair, so a keyboard or click adjustment persists too.
    private func persistWhenDragEnds(_ editing: Bool) {
        if !editing { store.commitPreviewedTypography() }
    }

    private var fontSize: Binding<Double> {
        Binding(get: { Double(configuration.typography.clampedFontSize) },
                set: { size in store.previewTypography { $0.fontSize = CGFloat(size) } })
    }

    private var lineSpacing: Binding<Double> {
        Binding(get: { Double(configuration.typography.clampedLineSpacing) },
                set: { spacing in store.previewTypography { $0.lineSpacing = CGFloat(spacing) } })
    }

    private var sessionScale: Binding<Double> {
        Binding(get: { configuration.sessionTypography.clampedScale },
                set: { v in store.previewConfiguration { $0.sessionTypography.scale = v } })
    }

    private var sessionLineHeight: Binding<Double> {
        Binding(get: { configuration.sessionTypography.clampedLineHeight },
                set: { v in store.previewConfiguration { $0.sessionTypography.lineHeight = v } })
    }

    private var composerSize: Binding<Double> {
        Binding(get: { Double(configuration.composerTypography.clampedFontSize) },
                set: { v in store.previewConfiguration { $0.composerTypography.fontSize = CGFloat(v) } })
    }

    private var frameSize: Binding<Double> {
        Binding(get: { Double(configuration.frameTypography.clampedBaseSize) },
                set: { v in store.previewConfiguration { $0.frameTypography.baseSize = CGFloat(v) } })
    }
}

/// Sets the hosting window's own appearance, which AppKit uses for the title bar and
/// the native tab strip. `nil` gives the window back to the system.
private struct WindowAppearance: NSViewRepresentable {
    let appearance: Appearance?

    func makeNSView(context: Context) -> WindowAppearanceView { WindowAppearanceView() }

    func updateNSView(_ view: WindowAppearanceView, context: Context) {
        view.pinned = appearance
    }
}

/// The view `WindowAppearance` hosts. It writes the appearance to its window when it
/// joins one, and again whenever the value changes.
private final class WindowAppearanceView: NSView {
    /// The shell's resolved appearance for the window, or `nil` for the system's.
    var pinned: Appearance? {
        didSet { applyToWindow() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    private func applyToWindow() {
        guard let pinned else {
            window?.appearance = nil
            return
        }
        window?.appearance = NSAppearance(named: pinned == .dark ? .darkAqua : .aqua)
    }
}
