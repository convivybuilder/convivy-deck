import AppKit
import SwiftUI

/// What the "Set Up…" action opens once the pre-install check reads a
/// reading with setup steps (CQ·160/CQ·200): those steps, chained and run
/// in a terminal over the host's ssh connection. The person types no
/// command; where a step asks for a sudo password or a sign-in
/// confirmation, they answer it here.
///
/// It runs once. When the pane exits the terminal stays, with its output,
/// and the line below it gives the result. Nothing is retried.
struct BuilderServerInstallSheet: View {
    let hostName: String
    let arguments: [String]
    let theme: TerminalTheme
    let appearance: Appearance
    let typography: TerminalTypography
    /// The port Deck forwarded for Builder's GitHub App page (CQ·202), or
    /// nil for a setup that never runs `.installBuilderServer` — see
    /// `BuilderServerInstall.forwardedPort`, the one place that decision is
    /// made.
    var githubAppPort: UInt16? = nil
    /// Called at most once per pane, with the exact URL `create-github-app`
    /// printed. Defaults to the real browser; tests inject a recorder.
    var openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Re-probes the host after a clean exit and reports whether Builder's
    /// server now answers.
    let verify: () async -> Bool
    /// Called once, when the re-probe finds the server.
    let onInstalled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .running
    /// Set once the pane's output has shown `create-github-app`'s Open
    /// line — whether or not opening it actually succeeded — so the status
    /// line can explain what the person is about to see in their browser.
    @State private var sawGithubAppOpenLine = false

    enum Phase: Equatable {
        case running
        case verifying
        case finished(BuilderServerInstall.Outcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setting up \u{201c}\(hostName)\u{201d}")
                .font(.headline)
            InstallerTerminalView(
                arguments: arguments, theme: theme, appearance: appearance, typography: typography,
                onExit: finish, githubAppPort: githubAppPort,
                openBrowser: { url in
                    sawGithubAppOpenLine = true
                    openBrowser(url)
                })
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
            return Self.runningStatusLine(
                hostName: hostName, createsGithubApp: githubAppPort != nil,
                sawGithubAppOpenLine: sawGithubAppOpenLine)
        case .verifying:
            return "Setup finished. Checking for Builder\u{2019}s server on \(hostName)\u{2026}"
        case .finished(let outcome):
            return Self.statusLine(for: outcome, hostName: hostName, githubAppPort: githubAppPort)
        }
    }

    /// The line under a running pane. `createsGithubApp` is true when Deck
    /// forwarded a port for Builder's GitHub App step, which happens only
    /// when the steps include Builder's installer; the App is then explained
    /// from the start, before its step runs (E22). Once the pane has printed
    /// the App page's Open line, the line says the page is in the browser.
    static func runningStatusLine(
        hostName: String, createsGithubApp: Bool, sawGithubAppOpenLine: Bool
    ) -> String {
        if createsGithubApp, sawGithubAppOpenLine {
            return "Builder needs its own GitHub App so its agents can open pull requests. GitHub is showing, "
                + "in your browser, the page where you click Create. Deck carries GitHub\u{2019}s redirect back "
                + "to \(hostName), so nothing needs pasting, even though the pane says the redirect will fail."
        }
        let running = "Setup is running. If the pane above shows a sign-in link, Command-click it or copy it "
            + "into your browser, approve the sign-in, and paste the code it gives you back into the pane, "
            + "then press Return. The code does not show as you paste it. If it is refused, the pane asks "
            + "again; paste it once more. "
            + "If \(hostName) asks for a sudo password or a confirmation, answer that in the pane too."
        guard createsGithubApp else { return running }
        return running + " Setup ends by creating Builder\u{2019}s own GitHub App, which its agents use to open "
            + "pull requests: Deck opens GitHub\u{2019}s page in your browser, and you click Create there."
    }

    static func statusLine(
        for outcome: BuilderServerInstall.Outcome, hostName: String, githubAppPort: UInt16? = nil
    ) -> String {
        switch outcome {
        case .installed:
            let base = "Builder\u{2019}s server is installed on \(hostName). Deck is setting up its steward."
            guard githubAppPort != nil else { return base }
            return base + " Builder\u{2019}s GitHub App now exists; install it on your repositories from "
                + "the address the pane shows above."
        case .exitedWithoutServer:
            return "Setup exited without an error, but Deck still cannot find Builder\u{2019}s "
                + "server on \(hostName). Its output is above. You can set it up again from \(hostName)\u{2019}s row."
        case .failed(let exitCode?):
            return "Setup stopped with exit status \(exitCode). Its message is above. Deck did "
                + "not retry; you can set it up again from \(hostName)\u{2019}s row."
        case .failed(nil):
            return "Setup was stopped before it finished. You can set it up again from "
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
