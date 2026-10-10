import SwiftUI

/// The licence notice as it appears under the version line in Settings › General:
/// the product and copyright lines from `NOTICE`, and a button that opens the
/// complete `NOTICE` and `LICENSE` in a sheet.
///
/// WHY A SHEET AND NOT INLINE. `NOTICE` is fifteen lines and `LICENSE` is the
/// full 202-line Apache text. Inline, they would make a preferences tab whose
/// controls are three rows tall into one that is mostly licence, and the tab has
/// a measured height floor that a taller body would push the version out of
/// (see `SettingsView.general`). The sheet scrolls, so its length costs the tab
/// nothing.
///
/// The text is selectable everywhere it is drawn, since a person asking for the
/// licence is usually about to paste it somewhere.
struct LicenceNoticeSection: View {
    let licence: LicenceNotice

    @State private var showsFullText = false

    var body: some View {
        switch licence.presentation {
        case .unavailable:
            // The missing case is stated rather than omitted, so a bundle built
            // without the files says so and does not look like a UI bug.
            Text(LicenceNotice.unavailableMessage)
                .font(.caption).foregroundStyle(.secondary)
        case .available(let headline):
            VStack(alignment: .leading, spacing: 4) {
                if let headline {
                    Text(headline)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Licence and notice…") { showsFullText = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .sheet(isPresented: $showsFullText) {
                LicenceTextSheet(licence: licence)
            }
        }
    }
}

/// The full-text sheet: the licence column in a scroll view, and a Done button.
struct LicenceTextSheet: View {
    let licence: LicenceNotice

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LicenceTextColumn(licence: licence)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
    }
}

/// `NOTICE` then `LICENSE`, each under its own file name. Monospaced, because the
/// Apache text is laid out with indentation that proportional type would flatten.
///
/// A file that is missing while its sibling is present says so under its own
/// heading, so a half-shipped bundle reads as what it is.
struct LicenceTextColumn: View {
    let licence: LicenceNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(licence.files, id: \.name) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.name).font(.headline)
                    if let text = file.text {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(LicenceNotice.missingFileMessage(file.name))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
