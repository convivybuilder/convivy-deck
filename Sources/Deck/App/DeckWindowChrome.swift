import AppKit
import SwiftUI

/// The window's title bar under each appearance preference.
///
/// Under Builder Default the title bar is transparent and full-size, so the
/// window's own background shows through it, and that background is
/// `StatusGround.ground`. The native title is hidden, because AppKit draws it
/// in the system's label colour and that colour cannot be solved against the
/// ground. `DeckTitleAccessory` draws the title instead, in
/// `StatusGround.primaryInk`.
///
/// Under every other preference the title bar is the system's own. Applying
/// `builderDefault: false` puts back each value this type changes, so leaving
/// Builder Default restores the native chrome. The shell decides `builderDefault`
/// from the preference, and nothing here reads the system appearance.
enum DeckWindowChrome {
    static func apply(to window: NSWindow, builderDefault: Bool) {
        let contentBefore = window.contentLayoutRect.size
        defer { keepContentSize(of: window, contentBefore) }
        if builderDefault {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(red: StatusGround.ground.red,
                                             green: StatusGround.ground.green,
                                             blue: StatusGround.ground.blue,
                                             alpha: 1)
            if !window.titlebarAccessoryViewControllers.contains(where: { $0 is DeckTitleAccessory }) {
                window.addTitlebarAccessoryViewController(DeckTitleAccessory())
            }
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.backgroundColor = .windowBackgroundColor
            if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 is DeckTitleAccessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }
    }
}

/// Changing the title bar's transparency moves where the content starts, and
/// AppKit can shrink the content by the title bar's height while doing it. The
/// window keeps its content size and its top edge, so the layout the user sees
/// does not change with the preference.
private func keepContentSize(of window: NSWindow, _ before: NSSize) {
    let after = window.contentLayoutRect.size
    let grow = before.height - after.height
    guard grow != 0 else { return }
    var frame = window.frame
    frame.size.height += grow
    frame.origin.y -= grow
    window.setFrame(frame, display: true)
}

/// The product's name and its part, drawn after the traffic-light buttons on the
/// ground. The accessory is as wide as its text, so the lockup is never clipped.
final class DeckTitleAccessory: NSTitlebarAccessoryViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
        let label = NSHostingView(rootView: DeckTitleLabel())
        label.frame = NSRect(x: 0, y: 0, width: label.fittingSize.width, height: 28)
        view = label
    }

    required init?(coder: NSCoder) { fatalError("DeckTitleAccessory is created in code only") }
}

/// "Convivy Builder" in semibold, a middle dot, then "Deck" in regular weight, on
/// one baseline. The brand is the name the decision puts first; Deck is the part,
/// shown second and lighter (`company/decisions/0020`). The dot, with 6pt either
/// side, keeps the two from reading as one title.
struct DeckTitleLabel: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Convivy Builder")
                .font(.system(size: 13, weight: .semibold))
            Text("·")
                .font(.system(size: 13, weight: .regular))
                .padding(.horizontal, 6)
            Text("Deck")
                .font(.system(size: 13, weight: .regular))
        }
        .foregroundStyle(Color(StatusGround.primaryInk))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(Color(StatusGround.ground))
    }
}

/// Hands the window this view sits in to `DeckWindowChrome`, again whenever the
/// preference changes.
struct WindowChromeSetter: NSViewRepresentable {
    let builderDefault: Bool

    func makeNSView(context: Context) -> ChromeView { ChromeView(builderDefault: builderDefault) }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.builderDefault = builderDefault
    }

    final class ChromeView: NSView {
        var builderDefault: Bool {
            didSet { applyToWindow() }
        }

        init(builderDefault: Bool) {
            self.builderDefault = builderDefault
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("ChromeView is created in code only") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToWindow()
        }

        private func applyToWindow() {
            guard let window else { return }
            DeckWindowChrome.apply(to: window, builderDefault: builderDefault)
        }
    }
}
