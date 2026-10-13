import SwiftUI

/// What the "Install Builder Server…" action opens once the pre-install
/// check reads ready (CQ·160): Builder's published installer, run in a
/// terminal over the host's ssh connection. The person types no command;
/// where the host asks for a sudo password, they type it here.
///
/// It runs once. When the installer exits the terminal stays, with its
/// output, and the line below it gives the result. Nothing is retried.
struct BuilderServerInstallSheet: View {
    let hostName: String
    let arguments: [String]
    let theme: TerminalTheme
    let appearance: Appearance
    let typography: TerminalTypography
    /// Re-probes the host after a clean exit and reports whether Builder's
    /// server now answers.
    let verify: () async -> Bool
    /// Called once, when the re-probe finds the server.
    let onInstalled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .running

    enum Phase: Equatable {
        case running
        case verifying
        case finished(BuilderServerInstall.Outcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installing Builder\u{2019}s server on \u{201c}\(hostName)\u{201d}")
                .font(.headline)
            InstallerTerminalView(
                arguments: arguments, theme: theme, appearance: appearance, typography: typography,
                onExit: finish)
                .frame(minHeight: 320)
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(phase == .finished(.installed) ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(phase == .running ? "Stop and Close" : "Close") { dismiss() }
                    .keyboardShortcut(phase == .running ? .cancelAction : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
    }

    private var statusLine: String {
        switch phase {
        case .running:
            return "The installer is running. If \(hostName) asks for a password, it is this "
                + "account\u{2019}s sudo password; type it in the terminal above."
        case .verifying:
            return "The installer finished. Checking for Builder\u{2019}s server on \(hostName)\u{2026}"
        case .finished(let outcome):
            return Self.statusLine(for: outcome, hostName: hostName)
        }
    }

    static func statusLine(for outcome: BuilderServerInstall.Outcome, hostName: String) -> String {
        switch outcome {
        case .installed:
            return "Builder\u{2019}s server is installed on \(hostName). Deck is setting up its steward."
        case .exitedWithoutServer:
            return "The installer exited without an error, but Deck still cannot find Builder\u{2019}s "
                + "server on \(hostName). Its output is above. You can install again from \(hostName)\u{2019}s row."
        case .failed(let exitCode?):
            return "The installer stopped with exit status \(exitCode). Its message is above. Deck did "
                + "not retry; you can install again from \(hostName)\u{2019}s row."
        case .failed(nil):
            return "The installer was stopped before it finished. You can install again from "
                + "\(hostName)\u{2019}s row."
        }
    }

    private func finish(_ exitCode: Int32?) {
        guard exitCode == 0 else {
            phase = .finished(BuilderServerInstall.outcome(exitCode: exitCode, serverFound: false))
            return
        }
        phase = .verifying
        Task {
            let found = await verify()
            let outcome = BuilderServerInstall.outcome(exitCode: exitCode, serverFound: found)
            phase = .finished(outcome)
            if outcome == .installed { onInstalled() }
        }
    }
}
