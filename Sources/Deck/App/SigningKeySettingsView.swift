import SwiftUI
import UniformTypeIdentifiers

/// Settings › Signing: this Mac's Secure Enclave signing key and its certificate.
///
/// Deck makes the key when this tab first opens and reuses it until it is
/// deleted here. Every signature needs a Touch ID press (or the account
/// password); Test signature is how a person checks that end to end. The
/// certificate is the one the Library's root-ca ceremony issued for this key;
/// Import certificate checks it and stores it beside the key.
struct SigningKeySettingsView: View {
    private let store: SigningKeyStore
    private let certificates: SigningCertificateStore
    private let heldSaves: HeldKBSaveStore

    @State private var state: SigningKeyPresentation.KeyState = .absent
    @State private var test: SigningTestOutcome?
    @State private var exported: SigningRequestExportOutcome?
    @State private var certificate: SigningCertificate?
    @State private var certificateError: String?
    @State private var choosingCertificate = false
    @State private var isSigning = false
    @State private var loaded = false
    @State private var held: [HeldKBSave] = []
    @State private var heldResults: [HeldKBSaves.SendResult] = []
    @State private var sendingHeld = false
    @State private var heldError: String?

    init(store: SigningKeyStore = SigningKeyStore(fileURL: SigningKeyStore.defaultFileURL(),
                                                  factory: SecureEnclaveSigningKeyFactory()),
         certificates: SigningCertificateStore = SigningCertificateStore(
            fileURL: SigningCertificateStore.defaultFileURL()),
         heldSaves: HeldKBSaveStore = .shared) {
        self.store = store
        self.certificates = certificates
        self.heldSaves = heldSaves
    }

    private var presentation: SigningKeyPresentation { SigningKeyPresentation(state: state, test: test) }

    var body: some View {
        Form {
            Section("Signing key") {
                Text(presentation.headline)
                if let fingerprint = presentation.fingerprintLine {
                    LabeledContent("Fingerprint:") { Text(fingerprint).monospaced().textSelection(.enabled) }
                }
                Text("The key is kept in this Mac's Secure Enclave and cannot leave it. Deck reuses it until you delete it. Every signature asks for Touch ID, or your account password on a Mac without it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Certificate request") {
                Text("Writes a certificate signing request for this key, for the Library's root-ca ceremony. Signing it asks for Touch ID once.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Export signing request") { runExport() }
                        .disabled(!presentation.canTest || isSigning)
                }
                exportOutcomeView
            }
            Section("Certificate") {
                Text("The Library's root-ca ceremony issues this Mac's signing certificate. Import checks it is for this key and signing-only, then stores it beside the key.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let certificate {
                    LabeledContent("Subject:") { Text(certificate.commonName ?? "none").textSelection(.enabled) }
                    LabeledContent("Machine:") { Text(certificate.machine ?? "none").textSelection(.enabled) }
                    LabeledContent("Expires:") { Text(certificate.notAfter.formatted(.iso8601)).textSelection(.enabled) }
                    LabeledContent("DER SHA-256:") {
                        Text(certificate.derSHA256Hex).monospaced().textSelection(.enabled)
                    }
                } else {
                    Text("This Mac has no signing certificate.")
                }
                if let certificateError {
                    Text(certificateError).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Import certificate") { choosingCertificate = true }
                        .disabled(!presentation.canTest || isSigning)
                }
            }
            Section("Held knowledge-base saves") {
                Text("A save made while the certificate was outside its validity window stays on this Mac. Importing a renewed certificate sends each one, with one Touch ID press each. A save that does not go out keeps its reason here, and Retry sends it again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if held.isEmpty {
                    Text("No saves are held.").foregroundStyle(.secondary)
                }
                ForEach(held) { save in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(save.documentId).monospaced().textSelection(.enabled)
                        Text(save.draftPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(save.reason.map { "Not sent: \($0)" } ?? "Waiting for a renewed certificate.")
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Retry") { retry(save) }
                            .disabled(!presentation.canTest || isSigning || sendingHeld || !certificateIsCurrent())
                        if !certificateIsCurrent() {
                            Text("The stored certificate is outside its validity window. Import a renewed certificate to send this save.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(heldResults) { result in
                    Text(result.summary).textSelection(.enabled)
                }
                if let heldError {
                    Text(heldError).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Button("Test signature") { runTest() }
                        .disabled(!presentation.canTest || isSigning)
                    if let line = presentation.testLine { Text(line).foregroundStyle(.secondary) }
                }
                HStack {
                    if case .absent = state {
                        Button("Create key") { load(creating: true) }
                    } else {
                        Button("Delete key", role: .destructive) { delete() }
                            .disabled(isSigning)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingCertificate, allowedContentTypes: [.data]) { result in
            importCertificate(result)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            load(creating: true)
            loadCertificate()
            reloadHeld()
        }
        // A direct save from an open editor can clear a hold listed here.
        .onReceive(NotificationCenter.default.publisher(for: .heldKBSavesDidChange)) { _ in
            reloadHeld()
        }
    }

    private func reloadHeld() {
        do {
            held = try heldSaves.all()
            heldError = nil
        } catch {
            held = []
            heldError = error.localizedDescription
        }
    }

    private func load(creating: Bool) {
        do {
            let key = creating ? try store.loadOrCreate() : try store.load()
            state = key.map { .present(fingerprint: SigningKeyFingerprint.of(publicKeyX963: $0.publicKeyX963)) } ?? .absent
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadCertificate() {
        do {
            certificate = try certificates.loadCertificate()
        } catch {
            certificate = nil
            certificateError = error.localizedDescription
        }
    }

    /// Checks the picked file against this Mac's key and stores it. Reading the
    /// key does not prompt for Touch ID, so this runs on the main thread.
    private func importCertificate(_ result: Result<URL, Error>) {
        certificateError = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let key = try store.load() else { throw SigningCertificateError.noSigningKey }
            let imported = try SigningCertificateImport.importCertificate(
                fileData: data,
                forSPKI: CertificateSigningRequest.subjectPublicKeyInfo(x963: key.publicKeyX963),
                now: Date(), into: certificates)
            certificate = imported
            sendHeld(try heldSaves.all(), key: key, certificatePEM: imported.pem)
        } catch {
            certificateError = error.localizedDescription
        }
    }

    /// Whether the stored certificate's window includes now. With no certificate
    /// stored, nothing can be sent, so this is false.
    private func certificateIsCurrent() -> Bool {
        guard let certificate else { return false }
        let now = Date()
        return now >= certificate.notBefore && now <= certificate.notAfter
    }

    /// Sends one held save again, with the stored certificate for this key.
    private func retry(_ save: HeldKBSave) {
        do {
            guard let key = try store.load() else {
                heldError = SigningCertificateError.noSigningKey.localizedDescription
                return
            }
            let pem = certificates.loadPEM(
                forSPKI: CertificateSigningRequest.subjectPublicKeyInfo(x963: key.publicKeyX963))
            sendHeld([save], key: key, certificatePEM: pem)
        } catch {
            heldError = error.localizedDescription
        }
    }

    /// Sends `saves` off the main thread, since each one blocks on Touch ID, then
    /// shows each outcome beside the import or retry that caused it.
    private func sendHeld(_ saves: [HeldKBSave], key: SigningKey, certificatePEM: String?) {
        guard !saves.isEmpty else { return }
        sendingHeld = true
        heldResults = []
        heldError = nil
        let heldSaves = heldSaves
        Task.detached {
            // The hosts come from the same theme.json the rail reads. A held save
            // naming a host outside it is refused in `HeldKBSaves.send`.
            let hosts = ThemeConfiguration.load().hosts.map { SSHTarget(user: $0.user, host: $0.address) }
            let batch = HeldKBSaves.send(
                saves, store: heldSaves, signingKey: key, certificatePEM: certificatePEM,
                configuredTargets: hosts)
            await MainActor.run {
                heldResults = batch.results
                sendingHeld = false
                reloadHeld()
                // After reloadHeld, which clears heldError on a clean read, so a
                // store failure is not hidden by it.
                heldError = batch.storeError
                NotificationCenter.default.post(name: .heldKBSavesDidChange, object: nil)
            }
        }
    }

    /// Removes the certificate before the key. A failure after the first step
    /// leaves a key with no certificate, which saves keep local; the reverse
    /// order could leave a certificate for a key that no longer exists.
    private func delete() {
        do {
            try certificates.delete()
            certificate = nil
            certificateError = nil
            try store.delete()
            test = nil
            state = .absent
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder private var exportOutcomeView: some View {
        switch exported {
        case nil:
            EmptyView()
        case .written(let path, let fingerprint):
            Text("Written to \(path)").textSelection(.enabled)
            LabeledContent("Public key SHA-256:") {
                Text(fingerprint).monospaced().textSelection(.enabled)
            }
        case .cancelled:
            Text("Cancelled. Nothing was written.").foregroundStyle(.secondary)
        case .failed(let why):
            Text("Failed: \(why)").foregroundStyle(.secondary)
        }
    }

    private func runTest() {
        isSigning = true
        test = nil
        let store = store
        Task.detached {
            let outcome: SigningTestOutcome
            do {
                outcome = SigningTestOutcome.run(try store.loadOrCreate())
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run { test = outcome; isSigning = false }
        }
    }

    private func runExport() {
        isSigning = true
        exported = nil
        let store = store
        Task.detached {
            let outcome: SigningRequestExportOutcome
            do {
                outcome = SigningRequestExportOutcome.run(try store.loadOrCreate(),
                                                          to: CertificateSigningRequest.defaultFileURL())
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run { exported = outcome; isSigning = false }
        }
    }
}
