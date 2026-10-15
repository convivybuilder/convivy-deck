import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import Deck

// MARK: - A tiny hand-rolled test PKI

/// DER building blocks shared by the certificates this file issues — the
/// same technique `SigningCertificateImportTests.CertificateFixture` uses,
/// generalized here to a real issuer/subject pair rather than one throwaway
/// self-signature, since this file needs an actual chain: a root a leaf's
/// issuer name matches byte-for-byte, and a second, unrelated root to prove
/// the foreign-root refusal.
private enum TestDER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var octets: [UInt8] = []
        var rest = count
        while rest > 0 {
            octets.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(octets.count)] + octets
    }

    static func seq(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func oid(_ bytes: [UInt8]) -> [UInt8] { tlv(0x06, bytes) }

    private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]

    /// The same commonName string always encodes to the same bytes, which is
    /// what makes `issuerCommonName` on a leaf byte-identical to its issuing
    /// root's own `subjectCommonName` — the match a real TLS chain build
    /// requires.
    static func name(commonName: String) -> [UInt8] {
        seq([tlv(0x31, seq([oid(commonNameOID), tlv(0x0C, Array(commonName.utf8))]))])
    }

    static func spki(_ x963: Data) -> [UInt8] {
        seq([seq([oid(TestPKI.ecPublicKeyOID), oid(TestPKI.prime256v1OID)]),
             tlv(0x03, [0x00] + [UInt8](x963))])
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%02ld%02ld%02ld%02ld%02ld%02ldZ",
                          c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return tlv(0x17, Array(text.utf8))
    }
}

/// Issues an X.509v3 certificate by hand, signed by a given issuer key over a
/// given issuer name — the one function every certificate in this file goes
/// through, root or leaf, self-signed or not, so the issuer/subject name
/// byte-match a real chain build needs comes from using the same `name(
/// commonName:)` encoder on both sides rather than from two independent
/// strings that merely read the same.
private enum TestPKI {
    static let ecPublicKeyOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    static let prime256v1OID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    static let ecdsaWithSHA256OID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    static let basicConstraintsOID: [UInt8] = [0x55, 0x1D, 0x13]
    static let keyUsageOID: [UInt8] = [0x55, 0x1D, 0x0F]
    static let extendedKeyUsageOID: [UInt8] = [0x55, 0x1D, 0x25]
    static let subjectAltNameOID: [UInt8] = [0x55, 0x1D, 0x11]
    static let serverAuthOID: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
    static let clientAuthOID: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]

    private static func extensionEntry(_ oid: [UInt8], critical: Bool, value: [UInt8]) -> [UInt8] {
        TestDER.seq([TestDER.oid(oid)] + (critical ? [TestDER.tlv(0x01, [0xFF])] : []) + [TestDER.tlv(0x04, value)])
    }

    static func certificateDER(
        subjectCommonName: String, subjectPublicKeyX963: Data,
        issuerCommonName: String, issuerKey: P256.Signing.PrivateKey, serial: UInt8,
        notBefore: Date, notAfter: Date, isCA: Bool, keyUsageByte: UInt8,
        extendedKeyUsageOIDs: [[UInt8]] = [], sanDNSNames: [String] = [], sanIPv4: [String] = []
    ) throws -> Data {
        var items: [[UInt8]] = [
            TestDER.tlv(0xA0, TestDER.tlv(0x02, [0x02])),
            TestDER.tlv(0x02, [serial]),
            TestDER.seq([TestDER.oid(ecdsaWithSHA256OID)]),
            TestDER.name(commonName: issuerCommonName),
            TestDER.seq([TestDER.utcTime(notBefore), TestDER.utcTime(notAfter)]),
            TestDER.name(commonName: subjectCommonName),
            TestDER.spki(subjectPublicKeyX963),
        ]
        var extensions: [[UInt8]] = [
            extensionEntry(basicConstraintsOID, critical: true,
                          value: TestDER.seq(isCA ? [TestDER.tlv(0x01, [0xFF])] : [])),
            extensionEntry(keyUsageOID, critical: true,
                          value: TestDER.tlv(0x03, [UInt8(keyUsageByte.trailingZeroBitCount)] + [keyUsageByte])),
        ]
        if !extendedKeyUsageOIDs.isEmpty {
            extensions.append(extensionEntry(extendedKeyUsageOID, critical: true,
                                            value: TestDER.seq(extendedKeyUsageOIDs.map(TestDER.oid))))
        }
        var sanEntries: [[UInt8]] = sanDNSNames.map { TestDER.tlv(0x82, Array($0.utf8)) }
        sanEntries += sanIPv4.map { TestDER.tlv(0x87, $0.split(separator: ".").compactMap { UInt8($0) }) }
        if !sanEntries.isEmpty {
            extensions.append(extensionEntry(subjectAltNameOID, critical: false, value: TestDER.seq(sanEntries)))
        }
        items.append(TestDER.tlv(0xA3, TestDER.seq(extensions)))
        let tbs = TestDER.seq(items)
        let signature = try issuerKey.signature(for: Data(tbs)).derRepresentation
        let der = TestDER.seq([tbs, TestDER.seq([TestDER.oid(ecdsaWithSHA256OID)]),
                              TestDER.tlv(0x03, [0x00] + [UInt8](signature))])
        return Data(der)
    }
}

/// One throwaway root plus the server and client leaves it issues — built
/// fresh per test, never committed, matching the done conditions'
/// "generate test certificates at test time; commit no key material."
private struct TestPKIFixture {
    let rootKey = P256.Signing.PrivateKey()
    let rootCommonName: String
    let rootCertificateDER: Data

    let serverKey = P256.Signing.PrivateKey()
    let serverCertificateDER: Data

    let clientKey = P256.Signing.PrivateKey()
    let clientCertificateDER: Data

    private static let notBefore = Date(timeIntervalSinceNow: -3600)
    private static let notAfter = Date(timeIntervalSinceNow: 3600)

    init(rootCommonName: String = "Convivy Library Test Root \(UUID().uuidString)") throws {
        self.rootCommonName = rootCommonName
        rootCertificateDER = try TestPKI.certificateDER(
            subjectCommonName: rootCommonName, subjectPublicKeyX963: rootKey.publicKey.x963Representation,
            issuerCommonName: rootCommonName, issuerKey: rootKey, serial: 1,
            notBefore: Self.notBefore, notAfter: Self.notAfter, isCA: true, keyUsageByte: 0x06)
        serverCertificateDER = try TestPKI.certificateDER(
            subjectCommonName: "localhost", subjectPublicKeyX963: serverKey.publicKey.x963Representation,
            issuerCommonName: rootCommonName, issuerKey: rootKey, serial: 2,
            notBefore: Self.notBefore, notAfter: Self.notAfter, isCA: false, keyUsageByte: 0xA0,
            extendedKeyUsageOIDs: [TestPKI.serverAuthOID], sanDNSNames: ["localhost"], sanIPv4: ["127.0.0.1"])
        clientCertificateDER = try TestPKI.certificateDER(
            subjectCommonName: "deck-test-client", subjectPublicKeyX963: clientKey.publicKey.x963Representation,
            issuerCommonName: rootCommonName, issuerKey: rootKey, serial: 3,
            notBefore: Self.notBefore, notAfter: Self.notAfter, isCA: false, keyUsageByte: 0x80,
            extendedKeyUsageOIDs: [TestPKI.clientAuthOID])
    }

    var rootCertificate: SecCertificate { secCertificate(rootCertificateDER) }
    var serverCertificate: SecCertificate { secCertificate(serverCertificateDER) }
    var clientCertificate: SecCertificate { secCertificate(clientCertificateDER) }

    var serverIdentity: SecIdentity {
        LibrarySecIdentity.make(certificate: serverCertificate, privateKey: secKey(serverKey))!
    }

    var clientIdentity: SecIdentity {
        LibrarySecIdentity.make(certificate: clientCertificate, privateKey: secKey(clientKey))!
    }

    private func secCertificate(_ der: Data) -> SecCertificate {
        SecCertificateCreateWithData(nil, der as CFData)!
    }

    private func secKey(_ key: P256.Signing.PrivateKey) -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            key.x963Representation as CFData, attributes as CFDictionary, &error)
        else {
            fatalError("could not build a SecKey from the test fixture's own key: \(String(describing: error))")
        }
        return secKey
    }
}

// MARK: - A minimal local TLS 1.3 server requiring a client certificate

/// Stands up one `NWListener` on an ephemeral loopback port, TLS 1.3, a
/// client certificate required and checked against the fixture's own root —
/// never the system trust store, since a test CA is never in it. Answers a
/// fixed 200 with a small JSON body to whatever bytes arrive, which is all
/// `LibraryMutualTLSClient` needs to prove a request landed.
private final class TestLibraryTLSServer {
    let port: UInt16
    private let listener: NWListener
    private let fixture: TestPKIFixture

    init(fixture: TestPKIFixture) throws {
        self.fixture = fixture
        let identity = sec_identity_create(fixture.serverIdentity)!
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(tlsOptions.securityProtocolOptions, true)
        let rootCertificate = fixture.rootCertificate
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, secTrustRef, complete in
                let trust = sec_trust_copy_ref(secTrustRef).takeRetainedValue()
                // This is the CLIENT's certificate, so it is checked as one:
                // the trust arrives with the server-side SSL policy, which
                // wants serverAuth and refuses a clientAuth leaf.
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(false, nil))
                let outcome = LibraryServerTrustEvaluator.evaluate(trust, anchors: [rootCertificate])
                complete(outcome == .trusted)
            },
            DispatchQueue(label: "test-library-tls-verify"))
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let semaphore = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state { semaphore.signal() }
        }
        listener.newConnectionHandler = { connection in
            TestLibraryTLSServer.serve(connection)
        }
        listener.start(queue: .global())
        _ = semaphore.wait(timeout: .now() + 5)
        boundPort = listener.port?.rawValue ?? 0
        port = boundPort
    }

    private static func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let body = "{}"
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        connection.start(queue: .global())
    }

    func stop() {
        listener.cancel()
    }
}

// MARK: - Tests

final class LibraryMutualTLSTests: XCTestCase {
    // MARK: `LibraryCurlCommand` — reading the GET/POST templates back

    func testParsesTheGETTemplatesPathAndTokenFileWithNoExplicitMethod() throws {
        let command = LibraryClient.coursesListRemoteCommand(product: "convivy-deck")
        let parsed = try XCTUnwrap(LibraryCurlCommand.parse(command))
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.path, "/courses?product=convivy-deck")
        XCTAssertEqual(parsed.tokenFile, WorkingCopyStore.libraryTokenFile)
    }

    func testParsesThePOSTTemplatesMethodAndPath() throws {
        let command = LibraryClient.itemApproveRemoteCommand(itemId: "issue_01ABC")
        let parsed = try XCTUnwrap(LibraryCurlCommand.parse(command))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/items/issue_01ABC/approve")
    }

    func testParsesThePUTTemplatesMethod() throws {
        let command = LibraryClient.courseOrderRemoteCommand(courseId: "course_01ABC")
        let parsed = try XCTUnwrap(LibraryCurlCommand.parse(command))
        XCTAssertEqual(parsed.method, "PUT")
    }

    func testParsesTheDocumentFetchTemplate() throws {
        let command = WorkingCopyStore.libraryDocumentRemoteCommand(kbId: "deck/bead/deck")
        let parsed = try XCTUnwrap(LibraryCurlCommand.parse(command))
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.path, "/reference/documents/deck/bead/deck")
    }

    func testAnUnrecognisedStringParsesToNil() {
        XCTAssertNil(LibraryCurlCommand.parse("echo hello"))
    }

    // MARK: `LibraryTransportSelector`

    private struct FakeIdentityProvider: LibraryClientIdentityProviding, @unchecked Sendable {
        let identity: SecIdentity?
        func identity(for host: SSHTarget) -> SecIdentity? { identity }
    }

    private struct FakeAnchorProvider: LibraryServerTrustAnchorProviding, @unchecked Sendable {
        let anchors: [SecCertificate]?
        func anchorCertificates(for host: SSHTarget) -> [SecCertificate]? { anchors }
    }

    func testTransportDisplayLabelsBothCasesForSettings() {
        XCTAssertEqual(LibraryTransportDisplay.label(.mutualTLS), "Mutual TLS")
        XCTAssertEqual(LibraryTransportDisplay.label(.existingPath), "Bearer token over ssh")
    }

    func testTheProductionSelectorStaysOnTheExistingPathWithNeitherSeamFilled() {
        XCTAssertEqual(LibraryTransportSelector.shared.transport(for: TestHost.target), .existingPath)
    }

    func testNoIdentityStaysOnTheExistingPathEvenWithAnAnchor() throws {
        let fixture = try TestPKIFixture()
        let selector = LibraryTransportSelector(
            identityProvider: FakeIdentityProvider(identity: nil),
            anchorProvider: FakeAnchorProvider(anchors: [fixture.rootCertificate]))
        XCTAssertEqual(selector.transport(for: TestHost.target), .existingPath)
    }

    func testAnIdentityWithNoAnchorStaysOnTheExistingPath() throws {
        let fixture = try TestPKIFixture()
        let selector = LibraryTransportSelector(
            identityProvider: FakeIdentityProvider(identity: fixture.clientIdentity),
            anchorProvider: FakeAnchorProvider(anchors: nil))
        XCTAssertEqual(selector.transport(for: TestHost.target), .existingPath)
    }

    func testBothSeamsFilledChoosesMutualTLS() throws {
        let fixture = try TestPKIFixture()
        let selector = LibraryTransportSelector(
            identityProvider: FakeIdentityProvider(identity: fixture.clientIdentity),
            anchorProvider: FakeAnchorProvider(anchors: [fixture.rootCertificate]))
        XCTAssertEqual(selector.transport(for: TestHost.target), .mutualTLS)
    }

    // MARK: `LibraryTransportDispatch` — the switch itself

    /// **CQ·162's own pin: no composer targets `127.0.0.1:8100` when a host
    /// is on mutual TLS.** The injected `existingPath` spy is the only thing
    /// in this test that could reach `8100` — it is the exact closure
    /// production wires to `SessionAgent.run` on the ssh argv — and it is
    /// never called when the selector has chosen `.mutualTLS`.
    func testMutualTLSNeverCallsTheExistingSSHPath() throws {
        let fixture = try TestPKIFixture()
        let selector = LibraryTransportSelector(
            identityProvider: FakeIdentityProvider(identity: fixture.clientIdentity),
            anchorProvider: FakeAnchorProvider(anchors: [fixture.rootCertificate]))
        var existingPathCalls = 0
        let argv = LibraryClient.coursesListArguments(target: TestHost.target, product: "convivy-deck")
        XCTAssertTrue(argv.last?.contains("127.0.0.1:8100") ?? false,
                     "the existing-path argv must still target the plain port, or this test proves nothing")

        let result = try LibraryTransportDispatch.run(
            target: TestHost.target, argv: argv, selector: selector,
            existingPath: { _, _ in
                existingPathCalls += 1
                return Data()
            },
            mutualTLSPath: { _, _, _ in Data("{}\n200".utf8) })

        XCTAssertEqual(existingPathCalls, 0, "mutual TLS must never fall through to the ssh/curl path")
        XCTAssertEqual(result, Data("{}\n200".utf8))
    }

    func testExistingPathTransportCallsOnlyTheSSHClosureWithTheUnchangedArgv() throws {
        let argv = LibraryClient.coursesListArguments(target: TestHost.target, product: "convivy-deck")
        var mutualTLSCalls = 0
        var capturedArgv: [String]?
        _ = try LibraryTransportDispatch.run(
            target: TestHost.target, argv: argv,
            selector: LibraryTransportSelector(
                identityProvider: FakeIdentityProvider(identity: nil),
                anchorProvider: FakeAnchorProvider(anchors: nil)),
            existingPath: { calledArgv, _ in
                capturedArgv = calledArgv
                return Data("{}\n200".utf8)
            },
            mutualTLSPath: { _, _, _ in
                mutualTLSCalls += 1
                return Data()
            })
        XCTAssertEqual(mutualTLSCalls, 0)
        XCTAssertEqual(capturedArgv, argv)
    }

    /// **A handshake/trust failure surfaces as that failure, never retried
    /// on the plain port.** No `catch` in `LibraryTransportDispatch.run`
    /// falls through from the mutual-TLS closure to the ssh one — this
    /// proves it by making the mutual-TLS closure throw and checking the ssh
    /// spy is never reached, for every one of the error's own cases.
    func testAMutualTLSFailureNeverFallsThroughToTheExistingPath() throws {
        let fixture = try TestPKIFixture()
        let selector = LibraryTransportSelector(
            identityProvider: FakeIdentityProvider(identity: fixture.clientIdentity),
            anchorProvider: FakeAnchorProvider(anchors: [fixture.rootCertificate]))
        for failure: LibraryMutualTLSError in [.handshakeFailed("simulated"), .trustRefused("simulated"),
                                               .transportFailed("simulated")] {
            var existingPathCalls = 0
            XCTAssertThrowsError(try LibraryTransportDispatch.run(
                target: TestHost.target,
                argv: LibraryClient.coursesListArguments(target: TestHost.target, product: "convivy-deck"),
                selector: selector,
                existingPath: { _, _ in existingPathCalls += 1; return Data() },
                mutualTLSPath: { _, _, _ in throw failure })
            ) { error in
                XCTAssertEqual(error as? LibraryMutualTLSError, failure)
            }
            XCTAssertEqual(existingPathCalls, 0, "\(failure) must not retry on the existing path")
        }
    }

    // MARK: `LibraryServerTrustEvaluator` — anchored to exactly one root

    func testTrustSucceedsAgainstItsOwnRoot() throws {
        let fixture = try TestPKIFixture()
        let trust = try makeTrust(leaf: fixture.serverCertificate)
        XCTAssertEqual(LibraryServerTrustEvaluator.evaluate(trust, anchors: [fixture.rootCertificate]), .trusted)
    }

    /// **The done condition itself: server trust refuses a certificate from
    /// a different root.** `foreign`'s server leaf is issued by its OWN
    /// root, never `fixture`'s — anchoring to `fixture`'s root alone must
    /// refuse it even though the leaf is, on its own terms, a perfectly
    /// valid certificate.
    func testTrustRefusesALeafFromAForeignRoot() throws {
        let fixture = try TestPKIFixture()
        let foreign = try TestPKIFixture()
        let trust = try makeTrust(leaf: foreign.serverCertificate)
        let outcome = LibraryServerTrustEvaluator.evaluate(trust, anchors: [fixture.rootCertificate])
        guard case .refused = outcome else {
            return XCTFail("a foreign-root leaf must be refused, got \(outcome)")
        }
    }

    private func makeTrust(leaf: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, "localhost" as CFString)
        let status = SecTrustCreateWithCertificates(leaf, policy, &trust)
        guard status == errSecSuccess, let trust else {
            throw LibraryTestSetupFailure("could not build a SecTrust for this test (status \(status))")
        }
        return trust
    }

    // MARK: Live round trip — the done condition needing a real local server

    /// **The headline done condition.** A local TLS 1.3 server requires a
    /// client certificate from this test's own CA; Deck's new transport
    /// reaches it and gets a real 200, while a plain HTTP request against
    /// the exact same port — what the existing composer would have sent had
    /// this host still been on the plain path — gets nothing usable back,
    /// because the listener only ever speaks TLS.
    ///
    /// NEEDS A REAL LOOPBACK SOCKET BIND. A listener that cannot start FAILS
    /// this test rather than skipping it: this is the done condition's own
    /// check, and a skip reads green on CI whether or not the transport
    /// works. Run the suite outside a sandbox that refuses `bind()`.
    func testTheMutualTLSRequestSucceedsWhileThePlainPathCannot() throws {
        let fixture = try TestPKIFixture()
        let server: TestLibraryTLSServer
        do {
            server = try TestLibraryTLSServer(fixture: fixture)
        } catch {
            throw LibraryTestSetupFailure("could not stand up a local TLS listener in this environment: \(error)")
        }
        defer { server.stop() }
        guard server.port != 0 else {
            throw LibraryTestSetupFailure("the local TLS listener never became ready in this environment")
        }

        let (status, body) = try LibraryMutualTLSClient.perform(
            method: "GET", baseURL: URL(string: "https://localhost:\(server.port)")!, path: "/whoami",
            headers: ["Library-Protocol": "1"], body: nil,
            identity: fixture.clientIdentity, anchors: [fixture.rootCertificate])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, Data("{}".utf8))

        // The plain-path composition cannot succeed against the same port:
        // a plaintext HTTP request hits a listener that only ever speaks
        // TLS and gets no valid HTTP response.
        let plainExpectation = expectation(description: "plain request completes")
        nonisolated(unsafe) var plainSucceeded = false
        // A TLS-only listener never answers plaintext HTTP, so this request
        // ends on its own timeout, which is one of the ways it cannot succeed.
        var plainRequest = URLRequest(url: URL(string: "http://localhost:\(server.port)/whoami")!)
        plainRequest.timeoutInterval = 2
        let plainTask = URLSession.shared.dataTask(with: plainRequest) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, error == nil {
                plainSucceeded = true
            }
            plainExpectation.fulfill()
        }
        plainTask.resume()
        wait(for: [plainExpectation], timeout: 10)
        XCTAssertFalse(plainSucceeded, "a plaintext request must not succeed against the TLS-only listener")
    }

    /// A client presenting no identity against a listener that requires one
    /// fails the handshake — `LibraryMutualTLSClient` surfaces that as
    /// `.trustRefused`/`.handshakeFailed`, never as a 200.
    func testNoClientIdentityFailsTheHandshake() throws {
        let fixture = try TestPKIFixture()
        let server: TestLibraryTLSServer
        do {
            server = try TestLibraryTLSServer(fixture: fixture)
        } catch {
            throw LibraryTestSetupFailure("could not stand up a local TLS listener in this environment: \(error)")
        }
        defer { server.stop() }
        guard server.port != 0 else {
            throw LibraryTestSetupFailure("the local TLS listener never became ready in this environment")
        }

        let noIdentity = try TestPKIFixture() // an unrelated, never-presented identity's root only
        XCTAssertThrowsError(try LibraryMutualTLSClient.perform(
            method: "GET", baseURL: URL(string: "https://localhost:\(server.port)")!, path: "/whoami",
            headers: [:], body: nil,
            identity: noIdentity.clientIdentity, anchors: [fixture.rootCertificate])
        ) { error in
            XCTAssertTrue(error is LibraryMutualTLSError, "expected a LibraryMutualTLSError, got \(error)")
        }
        // Positive control: the same server accepts the fixture's own client,
        // so the refusal above is the foreign identity's, not a broken server.
        let (status, _) = try LibraryMutualTLSClient.perform(
            method: "GET", baseURL: URL(string: "https://localhost:\(server.port)")!, path: "/whoami",
            headers: [:], body: nil,
            identity: fixture.clientIdentity, anchors: [fixture.rootCertificate])
        XCTAssertEqual(status, 200)
    }

    // MARK: The Library's two 401s, labelled by what each means

    func testA401FromTheBindingGateReadsAsCredentialNotBound() {
        let body = Data(#"{"detail":"this credential is not bound to the presenting machine"}"#.utf8)
        guard case .credentialNotBound = LibraryTransportDispatch.refusal(body: body) else {
            return XCTFail("expected .credentialNotBound")
        }
    }

    func testA401WithNoResolvableIdentityReadsAsMachineNotRegistered() {
        let body = Data(#"{"detail":"no resolvable identity"}"#.utf8)
        guard case .machineNotRegistered = LibraryTransportDispatch.refusal(body: body) else {
            return XCTFail("expected .machineNotRegistered")
        }
    }

    func testAnUnrecognised401StaysARefusal() {
        guard case .unauthorized = LibraryTransportDispatch.refusal(body: Data("nope".utf8)) else {
            return XCTFail("expected .unauthorized")
        }
    }

    // MARK: The token read validates its destination

    func testAHostileTargetGetsNoTokenReadArgv() {
        XCTAssertThrowsError(try LibraryHostConnection.readTokenArguments(
            target: SSHTarget(user: "deck", host: "-oProxyCommand=touch /tmp/x"), tokenFile: "/x"))
        XCTAssertThrowsError(try LibraryHostConnection.readTokenArguments(
            target: SSHTarget(user: "-l root", host: "kestrel"), tokenFile: "/x"))
    }
}

/// A test fixture that could not be built. Thrown in place of `XCTSkip`, so a
/// live check that cannot run reads as a failure.
private struct LibraryTestSetupFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
