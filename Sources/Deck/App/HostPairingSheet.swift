import SwiftUI

/// Pairs one account on a Mac: shows the host key's fingerprint for the
/// operator to compare, trusts it on confirmation, installs the laptop's
/// public key with one password entry, and runs Test. See `HostPairing` for
/// what each step writes and why.
///
/// THE PASSWORD IS HELD IN `password` FOR ONE ATTEMPT. It is copied into a
/// local and cleared before the install call starts, so a refused password
/// leaves nothing in the field to resend, and dismissing the sheet clears it
/// too.
struct HostPairingSheet: View {
    let target: SSHTarget
    /// Called once, with the Test result, after the key is installed. Not
    /// called when the operator cancels or a step fails: nothing new was
    /// tested then. A refused Test keeps the sheet open with the reason.
    let onFinished: (HostTestOutcome) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .scanning
    @State private var scanned: HostPairing.ScannedHostKey?
    @State private var publicKey: HostPairing.PublicKey?
    @State private var password = ""
    @State private var notice: String?

    enum Phase {
        case scanning
        case confirm
        case working(String)
        case password
        case failed

        /// Off while trust or install runs. Those steps run detached and ignore
        /// cancellation, so a dismissed sheet would still write known_hosts or
        /// the key and show no result.
        var allowsCancel: Bool {
            if case .working = self { return false }
            return true
        }
    }

    private var knownHostsPath: String { "\(NSHomeDirectory())/.ssh/known_hosts" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair \(target.user)@\(target.host)")
                .font(.headline)

            content

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    password = ""
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!phase.allowsCancel)
                footerAction
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await scan() }
        // Escape and other interactive dismissals bypass the disabled Cancel
        // button, so the sheet itself refuses them while a write runs.
        .interactiveDismissDisabled(!phase.allowsCancel)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            working("Fetching the host key\u{2026}")
        case .working(let text):
            working(text)
        case .confirm:
            if let scanned {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compare this fingerprint with the one the Mac\u{2019}s install printed.")
                    Text(HostPairing.displayFingerprint(scanned))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Trust only if they match. Trusting writes this key to \(knownHostsPath) "
                         + "under \(target.host), so Terminal trusts it too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .password:
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the password for \(target.user)@\(target.host). Deck uses it for this "
                     + "one connection and does not store it.")
                SecureField("Password", text: $password)
                    .onSubmit { Task { await install() } }
            }
        case .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footerAction: some View {
        switch phase {
        case .confirm:
            Button("Trust") { Task { await trust() } }
                .keyboardShortcut(.defaultAction)
        case .password:
            Button("Install Key") { Task { await install() } }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        case .scanning, .working, .failed:
            EmptyView()
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // MARK: - Steps

    private func scan() async {
        phase = .scanning
        let target = target
        do {
            scanned = try await Task.detached { try HostPairing.scan(target: target) }.value
            phase = .confirm
        } catch {
            notice = describe(error)
            phase = .failed
        }
    }

    /// Step 1 and step 2. Trust writes the key the operator was shown, which is
    /// `scanned` itself, not a fresh scan. Step 2 then picks or creates the
    /// laptop key.
    private func trust() async {
        guard let key = scanned else { return }
        phase = .working("Writing the host key to known_hosts\u{2026}")
        let address = target.host
        do {
            try await Task.detached { try HostPairing.trust(key, address: address) }.value
            phase = .working("Choosing a laptop key\u{2026}")
            publicKey = try await Task.detached { try HostPairing.ensureIdentity() }.value
            notice = nil
            phase = .password
        } catch {
            notice = describe(error)
            phase = .failed
        }
    }

    /// Step 3, then step 4. The password is cleared from the view before the
    /// call starts. A refused password returns to the password step with the
    /// key still chosen; any other failure ends the sheet's attempt.
    private func install() async {
        guard let key = publicKey, !password.isEmpty else { return }
        let entered = password
        password = ""
        phase = .working("Installing the key on the account\u{2026}")
        let target = target
        do {
            let outcome = try await Task.detached {
                try HostPairing.install(key, target: target, password: entered)
            }.value
            switch outcome {
            case .added(let path), .alreadyPresent(let path):
                // The key is on the account, so a refused Test is a login Deck
                // cannot make with the key it installed. The sheet stays open to
                // say so; any other Test result closes it as before. The path
                // names the file the remote verified, so a $HOME mismatch shows.
                phase = .working("Installed in \(path). Running Test\u{2026}")
                let test = await HostProbe.test(target: target)
                onFinished(test)
                if case .refused = test {
                    notice = HostPairing.note(afterTest: test) + "\nWritten to \(path)."
                    phase = .failed
                } else {
                    notice = nil
                    dismiss()
                }
            case .passwordRefused:
                notice = "That password was refused. Enter it again."
                phase = .password
            case .failed(let text):
                notice = text
                phase = .failed
            }
        } catch {
            notice = describe(error)
            phase = .failed
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? HostPairingError)?.message ?? "\(error)"
    }
}
