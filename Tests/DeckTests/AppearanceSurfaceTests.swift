import Foundation
import SwiftUI
import XCTest
@testable import Deck

/// The one mapping from surface to appearance, pinned from both sides: what
/// `Builder Default` must draw, and what `system`, `light` and `dark` must keep drawing
/// exactly as they did before `Builder Default` existed.
final class AppearanceSurfaceTests: XCTestCase {
    private let statusSurfaces: [AppearanceSurface] = [.rail, .start, .run, .chrome, .strip]
    private let workSurfaces: [AppearanceSurface] = [.cockpit, .conversation, .terminal, .document, .slate]

    private func config(_ preference: ThemeConfiguration.AppearancePreference) -> ThemeConfiguration {
        var config = ThemeConfiguration.empty
        config.appearancePreference = preference
        return config
    }

    // MARK: - The partition covers every surface, once

    /// Every surface is named in exactly one list, so a new case cannot quietly
    /// fall into one half of the Builder Default without a decision being written down.
    func testEverySurfaceIsOnExactlyOneSideOfBuilderDefault() {
        XCTAssertEqual(statusSurfaces.count + workSurfaces.count, AppearanceSurface.allCases.count)
        XCTAssertEqual(Set(statusSurfaces + workSurfaces), Set(AppearanceSurface.allCases))
    }

    // MARK: - Builder Default

    /// Status panes are dark and work panes are light, whichever way the system
    /// is set. The cockpit is a work pane: it draws on its session's composer
    /// tint, which is light. Both system values are run, so a result that tracks
    /// the system fails here.
    func testBuilderDefaultDrawsStatusDarkAndWorkLightWhateverTheSystemSays() {
        let builderDefault = config(.builderDefault)
        for systemIsDark in [true, false] {
            for surface in statusSurfaces {
                XCTAssertEqual(builderDefault.appearance(for: surface, systemIsDark: systemIsDark), .dark,
                               "\(surface) should be dark under Builder Default with systemIsDark=\(systemIsDark)")
            }
            for surface in workSurfaces {
                XCTAssertEqual(builderDefault.appearance(for: surface, systemIsDark: systemIsDark), .light,
                               "\(surface) should be light under Builder Default with systemIsDark=\(systemIsDark)")
            }
        }
    }

    // MARK: - The existing presets are unchanged

    /// `system` follows the system for every surface, so adding a surface
    /// never changes what the system preset draws.
    func testSystemFollowsTheSystemForEverySurface() {
        for surface in AppearanceSurface.allCases {
            XCTAssertEqual(config(.system).appearance(for: surface, systemIsDark: true), .dark)
            XCTAssertEqual(config(.system).appearance(for: surface, systemIsDark: false), .light)
        }
    }

    /// `light` and `dark` ignore the system and answer the same for every
    /// surface. Under the new case they still must not Builder Default.
    func testLightAndDarkAnswerTheSameForEverySurface() {
        for surface in AppearanceSurface.allCases {
            for systemIsDark in [true, false] {
                XCTAssertEqual(config(.light).appearance(for: surface, systemIsDark: systemIsDark), .light)
                XCTAssertEqual(config(.dark).appearance(for: surface, systemIsDark: systemIsDark), .dark)
            }
        }
    }

    // MARK: - Pinning

    /// `light`, `dark` and `Builder Default` pin every surface to the appearance it
    /// draws in. `system` pins none, so native chrome keeps drawing from the system scheme.
    func testEveryPresetButSystemPinsEverySurfaceToItsAppearance() {
        for surface in AppearanceSurface.allCases {
            XCTAssertNil(config(.system).pinnedAppearance(for: surface))
            XCTAssertEqual(config(.light).pinnedAppearance(for: surface), .light)
            XCTAssertEqual(config(.dark).pinnedAppearance(for: surface), .dark)
            XCTAssertEqual(config(.builderDefault).pinnedAppearance(for: surface),
                           config(.builderDefault).appearance(for: surface, systemIsDark: false))
        }
    }

    /// A pinned surface draws in the appearance `appearance(for:systemIsDark:)` gives it,
    /// whichever way the system is set. `system` is the one preset whose pin follows
    /// the system, so it pins nothing and its surfaces track the system scheme.
    func testPinnedAppearanceMatchesTheSurfaceAppearanceForEverySystemScheme() {
        for preference in [ThemeConfiguration.AppearancePreference.light, .dark, .builderDefault] {
            for surface in AppearanceSurface.allCases {
                for systemIsDark in [true, false] {
                    XCTAssertEqual(config(preference).pinnedAppearance(for: surface),
                                   config(preference).appearance(for: surface, systemIsDark: systemIsDark),
                                   "\(preference) must pin \(surface) to its appearance with systemIsDark=\(systemIsDark)")
                }
            }
        }
    }

    /// The reconnect veil writes the terminal's pinned scheme under every preset but
    /// `system`, so the spinner matches the terminal beside it. Under `system` it
    /// writes none and draws from the window's scheme.
    func testVeilWritesThePinnedTerminalScheme() {
        func veilScheme(_ preference: ThemeConfiguration.AppearancePreference) -> ColorScheme? {
            ReconnectingVeil.pinnedScheme(for: config(preference).pinnedAppearance(for: .terminal))
        }
        XCTAssertNil(veilScheme(.system))
        XCTAssertEqual(veilScheme(.light), .light)
        XCTAssertEqual(veilScheme(.dark), .dark)
        XCTAssertEqual(veilScheme(.builderDefault), .light)
    }

    // MARK: - The status ground

    /// Under Builder Default each status surface is pinned dark on the status
    /// ground, and each work surface is pinned light with no ground of its own.
    /// The cockpit's ground is set by `ContentView` from the selected session,
    /// so its generic pin carries none here.
    /// The ground is read from `StatusGround`, so a change to that one value
    /// reaches the pins without touching this test.
    func testBuilderDefaultPinsStatusSurfacesOnTheStatusGround() {
        let builderDefault = config(.builderDefault)
        for surface in statusSurfaces {
            XCTAssertEqual(builderDefault.pinnedSurface(for: surface),
                           PinnedSurface(appearance: .dark, ground: StatusGround.ground),
                           "\(surface) should draw on the status ground")
        }
        for surface in workSurfaces {
            XCTAssertEqual(builderDefault.pinnedSurface(for: surface),
                           PinnedSurface(appearance: .light, ground: nil),
                           "\(surface) should draw light with no status ground")
        }
    }

    /// `light` and `dark` pin each surface to its scheme with no status ground, so
    /// their status panes keep the system's own ground. `system` pins nothing.
    func testLightAndDarkPinTheirSchemeWithNoStatusGround() {
        for surface in AppearanceSurface.allCases {
            XCTAssertNil(config(.system).pinnedSurface(for: surface), "system must not pin \(surface)")
            XCTAssertEqual(config(.light).pinnedSurface(for: surface),
                           PinnedSurface(appearance: .light, ground: nil), "light must pin \(surface) light")
            XCTAssertEqual(config(.dark).pinnedSurface(for: surface),
                           PinnedSurface(appearance: .dark, ground: nil), "dark must pin \(surface) dark")
        }
    }

    // MARK: - Unpinned windows

    /// The window-wide value is the main window's chrome appearance, so a window with
    /// no pane of its own, such as Settings, draws the way the chrome above the main
    /// pane does. Under `Builder Default` that is dark whatever the system says.
    func testWindowAppearanceIsTheChromeAppearance() {
        for systemIsDark in [true, false] {
            XCTAssertEqual(config(.system).windowAppearance(systemIsDark: systemIsDark),
                           systemIsDark ? .dark : .light)
            XCTAssertEqual(config(.light).windowAppearance(systemIsDark: systemIsDark), .light)
            XCTAssertEqual(config(.dark).windowAppearance(systemIsDark: systemIsDark), .dark)
            XCTAssertEqual(config(.builderDefault).windowAppearance(systemIsDark: systemIsDark), .dark)
        }
    }

    /// Settings pins to the chrome's surface, so `Builder Default` gives it the status
    /// ground, and `system` leaves it on the system scheme.
    func testSettingsWindowPinsLikeTheChrome() {
        for systemIsDark in [true, false] {
            XCTAssertNil(config(.system).pinnedSurface(for: .chrome))
            XCTAssertEqual(config(.light).pinnedSurface(for: .chrome),
                           PinnedSurface(appearance: .light, ground: nil))
            XCTAssertEqual(config(.dark).pinnedSurface(for: .chrome),
                           PinnedSurface(appearance: .dark, ground: nil))
            XCTAssertEqual(config(.builderDefault).pinnedSurface(for: .chrome),
                           PinnedSurface(appearance: .dark, ground: StatusGround.ground))
        }
    }

    /// The divider between the main pane and the right column pins under `light` and
    /// `dark` only. `builderDefault` and `system` leave it on the system scheme, so its
    /// drawing there does not change.
    func testDividerPinsOnlyUnderLightAndDark() {
        XCTAssertNil(config(.system).pinnedDividerSurface)
        XCTAssertNil(config(.builderDefault).pinnedDividerSurface)
        XCTAssertEqual(config(.light).pinnedDividerSurface,
                       PinnedSurface(appearance: .light, ground: nil))
        XCTAssertEqual(config(.dark).pinnedDividerSurface,
                       PinnedSurface(appearance: .dark, ground: nil))
    }

    // MARK: - Column occupants

    /// Each right-column occupant draws as the surface it is. A case added to
    /// `ColumnOccupant` must be decided here.
    func testEveryColumnOccupantDrawsAsItsSurface() {
        let target = TestHost.target
        XCTAssertEqual(ColumnOccupant.cockpit.appearanceSurface, .cockpit)
        XCTAssertEqual(ColumnOccupant.remoteShell.appearanceSurface, .terminal)
        XCTAssertEqual(ColumnOccupant.localTerminal.appearanceSurface, .terminal)
        XCTAssertEqual(ColumnOccupant.viewer(ref: .path(absolutePath: "/x"), target: target).appearanceSurface,
                       .document)
        XCTAssertEqual(ColumnOccupant.editor(ref: .path(absolutePath: "/x"), target: target).appearanceSurface,
                       .document)
        XCTAssertEqual(ColumnOccupant.item(id: "issue_A", target: target).appearanceSurface, .document)
        XCTAssertEqual(ColumnOccupant.reviewRecords(repo: "r", pr: 1, headSha: nil, target: target)
            .appearanceSurface, .document)
        XCTAssertEqual(ColumnOccupant.run(runId: "run_1").appearanceSurface, .run)
        XCTAssertEqual(ColumnOccupant.slate(session: "vivy", target: target,
                                            crew: SessionRef(host: "mini", name: "vivy")).appearanceSurface,
                       .slate)
    }

    // MARK: - Configuration file

    /// `"split"` was this preference's name before it became Builder Default.
    /// A file that still says it reads as Builder Default, so the choice a user
    /// made before the rename keeps its meaning.
    func testLegacySplitValueParsesAsBuilderDefault() throws {
        let data = try XCTUnwrap(#"{"appearance":"split"}"#.data(using: .utf8))
        let parsed = try XCTUnwrap(ThemeConfiguration.parse(data))
        XCTAssertEqual(parsed.appearancePreference, .builderDefault)
    }

    /// An unrecognised value still degrades to `system`, the per-field fallback
    /// every other key follows, so it draws the system scheme rather than failing.
    func testAnUnknownAppearanceStillDegradesToSystem() throws {
        let data = try XCTUnwrap(#"{"appearance":"graphite"}"#.data(using: .utf8))
        let parsed = try XCTUnwrap(ThemeConfiguration.parse(data))
        XCTAssertEqual(parsed.appearancePreference, .system)
    }
}
