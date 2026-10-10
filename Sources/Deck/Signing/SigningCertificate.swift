import CryptoKit
import Foundation

/// A signing certificate the Library's root-ca ceremony issued for this Mac's
/// Secure Enclave key, read from its DER by hand.
///
/// The fields are the ones `SigningCertificateImport` checks and Settings shows.
/// Deck does not verify the issuer's signature or the chain to the Library root:
/// `platform/contracts/library-protocol` §2.2 assigns the chain check to
/// `kb apply`, the verifier, and names no Deck-side chain check.
struct SigningCertificate: Equatable {
    struct KeyUsage: Equatable {
        let critical: Bool
        /// The asserted bit positions, RFC 5280 §4.2.1.3. digitalSignature is 0.
        let bits: Set<Int>
    }

    struct ExtendedKeyUsage: Equatable {
        let critical: Bool
        /// Each purpose as the content bytes of its OBJECT IDENTIFIER.
        let purposes: [[UInt8]]
    }

    /// The certificate's DER encoding, the bytes `derSHA256Hex` hashes.
    let der: Data
    /// The `SubjectPublicKeyInfo` bytes as the certificate carries them. The key
    /// match compares these bytes against Deck's own key's SPKI.
    let spkiDER: Data
    let notBefore: Date
    let notAfter: Date
    /// The subject's commonName, which the ceremony sets to the person's email.
    let commonName: String?
    /// The `<machine>` from the `convivy://signer/<machine>` subjectAltName URI.
    let machine: String?
    /// The keyUsage extension, or nil when the certificate has none.
    let keyUsage: KeyUsage?
    /// The extendedKeyUsage extension, or nil when the certificate has none.
    let extendedKeyUsage: ExtendedKeyUsage?
    /// The basicConstraints `cA` flag, or nil when the extension is absent.
    let isCA: Bool?

    /// The keyUsage bit positions the contract allows: digitalSignature only.
    static let digitalSignatureBit = 0

    /// The contract's signing purpose, `2.25.332679538808142797592760871621889796493`
    /// (`platform/contracts/library-protocol` §2.2), as OID content bytes.
    static let signingPurpose: [UInt8] = [
        0x69, 0x83, 0xF4, 0xC7, 0xDF, 0xE8, 0xC3, 0xF8, 0xD2, 0xB4,
        0xFB, 0x8E, 0xC4, 0xB4, 0xF9, 0xAB, 0x9E, 0xAA, 0xD3, 0x0D,
    ]

    /// Lowercase hex SHA-256 of `der`: the 64-character fingerprint Settings shows.
    var derSHA256Hex: String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The certificate as the PEM text Deck stores beside the signing key.
    var pem: String {
        let base64 = Array(der.base64EncodedString())
        var lines = ["-----BEGIN CERTIFICATE-----"]
        for start in stride(from: 0, to: base64.count, by: 64) {
            lines.append(String(base64[start..<min(start + 64, base64.count)]))
        }
        lines.append("-----END CERTIFICATE-----")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a certificate from a file's bytes, which are PEM text with one
    /// `CERTIFICATE` block or a single DER certificate.
    static func parse(fileData: Data) throws -> SigningCertificate {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        guard let text = String(data: fileData, encoding: .utf8), text.contains(begin) else {
            return try parse(der: fileData)
        }
        guard text.components(separatedBy: begin).count == 2,
              let open = text.range(of: begin), let close = text.range(of: end),
              open.upperBound <= close.lowerBound else {
            throw SigningCertificateError.notACertificate("expected exactly one PEM certificate")
        }
        guard let der = Data(base64Encoded: String(text[open.upperBound..<close.lowerBound]),
                             options: .ignoreUnknownCharacters) else {
            throw SigningCertificateError.notACertificate("the PEM body is not base64")
        }
        return try parse(der: der)
    }

    static func parse(der: Data) throws -> SigningCertificate {
        let (certificate, trailing) = try DERElement.split([UInt8](der))
        guard trailing.isEmpty, certificate.tag == 0x30 else {
            throw SigningCertificateError.notACertificate("the bytes are not one DER certificate")
        }
        let parts = try certificate.children()
        guard parts.count == 3, parts[0].tag == 0x30 else {
            throw SigningCertificateError.notACertificate("there is no tbsCertificate")
        }

        // The version is optional and explicitly tagged. After it come serial,
        // signature, issuer, validity, subject and the SubjectPublicKeyInfo.
        var fields = try parts[0].children()
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 6 else {
            throw SigningCertificateError.notACertificate("the tbsCertificate is missing fields")
        }
        let validity = fields[3]
        let subject = fields[4]
        let spki = fields[5]
        guard validity.tag == 0x30, spki.tag == 0x30, subject.tag == 0x30 else {
            throw SigningCertificateError.notACertificate("the tbsCertificate fields are out of order")
        }
        let times = try validity.children()
        guard times.count == 2 else {
            throw SigningCertificateError.notACertificate("validity does not hold two times")
        }
        // The root-ca tool signs with ecdsa-with-SHA256 in both places (library-protocol §2.2).
        guard try signatureAlgorithmOID(fields[1]) == OID.ecdsaWithSHA256,
              try signatureAlgorithmOID(parts[1]) == OID.ecdsaWithSHA256 else {
            throw SigningCertificateError.notACertificate("the signature algorithm is not ecdsa-with-SHA256")
        }

        let found = try extensionsByOID(in: fields)
        // RFC 5280 §4.2: a relying party must reject a certificate carrying a
        // critical extension it does not process. These are the four Deck reads.
        let processed = [OID.keyUsage, OID.extendedKeyUsage, OID.basicConstraints, OID.subjectAltName]
        if found.contains(where: { $0.value.critical && !processed.contains($0.key) }) {
            throw SigningCertificateError.notACertificate("it has a critical extension Deck does not read")
        }
        var keyUsage: KeyUsage?
        if let ext = found[OID.keyUsage] {
            keyUsage = KeyUsage(critical: ext.critical, bits: try bitPositions(ext.value))
        }
        var extendedKeyUsage: ExtendedKeyUsage?
        if let ext = found[OID.extendedKeyUsage] {
            extendedKeyUsage = ExtendedKeyUsage(critical: ext.critical, purposes: try purposes(ext.value))
        }
        var isCA: Bool?
        if let ext = found[OID.basicConstraints] {
            isCA = try basicConstraintsCA(ext.value)
        }

        return SigningCertificate(
            der: der,
            spkiDER: Data(spki.encoding),
            notBefore: try time(times[0]),
            notAfter: try time(times[1]),
            commonName: try commonName(in: subject),
            machine: try machine(in: found[OID.subjectAltName]?.value),
            keyUsage: keyUsage,
            extendedKeyUsage: extendedKeyUsage,
            isCA: isCA)
    }

    // MARK: - Fields

    private enum OID {
        static let commonName: [UInt8] = [0x55, 0x04, 0x03]
        static let subjectAltName: [UInt8] = [0x55, 0x1D, 0x11]
        static let keyUsage: [UInt8] = [0x55, 0x1D, 0x0F]
        static let basicConstraints: [UInt8] = [0x55, 0x1D, 0x13]
        static let extendedKeyUsage: [UInt8] = [0x55, 0x1D, 0x25]
        static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    }

    private typealias RawExtension = (critical: Bool, value: [UInt8])

    /// The algorithm OID content in an AlgorithmIdentifier SEQUENCE.
    private static func signatureAlgorithmOID(_ algorithm: DERElement) throws -> [UInt8] {
        guard algorithm.tag == 0x30, let oid = try algorithm.children().first, oid.tag == 0x06 else {
            throw SigningCertificateError.notACertificate("a signature algorithm is malformed")
        }
        return oid.content
    }

    /// The extensions by OID content bytes. A certificate that names one twice
    /// is refused, since the second copy could be read as the one that counts.
    private static func extensionsByOID(in fields: [DERElement]) throws -> [[UInt8]: RawExtension] {
        guard let wrapper = fields.first(where: { $0.tag == 0xA3 }) else { return [:] }
        let lists = try wrapper.children()
        guard lists.count == 1, lists[0].tag == 0x30 else {
            throw SigningCertificateError.notACertificate("the extensions are not a list")
        }
        var found: [[UInt8]: RawExtension] = [:]
        for item in try lists[0].children() {
            let parts = try item.children()
            guard let oid = parts.first, oid.tag == 0x06, let value = parts.last, value.tag == 0x04 else {
                throw SigningCertificateError.notACertificate("an extension is malformed")
            }
            let critical: Bool
            switch parts.count {
            case 2: critical = false
            // BER reads any nonzero content octet as TRUE, so 0x01 and 0xFF both mark the extension critical.
            case 3 where parts[1].tag == 0x01: critical = parts[1].content.contains { $0 != 0 }
            default: throw SigningCertificateError.notACertificate("an extension is malformed")
            }
            guard found[oid.content] == nil else {
                throw SigningCertificateError.notACertificate("an extension appears twice")
            }
            found[oid.content] = (critical, value.content)
        }
        return found
    }

    /// The bit positions in a BIT STRING wrapped in an extension's value.
    private static func bitPositions(_ value: [UInt8]) throws -> Set<Int> {
        let (bits, _) = try DERElement.split(value)
        guard bits.tag == 0x03, !bits.content.isEmpty else {
            throw SigningCertificateError.notACertificate("keyUsage is not a bit string")
        }
        var positions: Set<Int> = []
        for (index, byte) in bits.content.dropFirst().enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                positions.insert(index * 8 + bit)
            }
        }
        return positions
    }

    private static func purposes(_ value: [UInt8]) throws -> [[UInt8]] {
        let (list, _) = try DERElement.split(value)
        guard list.tag == 0x30 else {
            throw SigningCertificateError.notACertificate("extendedKeyUsage is not a list")
        }
        return try list.children().map { purpose in
            guard purpose.tag == 0x06 else {
                throw SigningCertificateError.notACertificate("an extendedKeyUsage purpose is not an OID")
            }
            return purpose.content
        }
    }

    private static func basicConstraintsCA(_ value: [UInt8]) throws -> Bool {
        let (sequence, _) = try DERElement.split(value)
        guard sequence.tag == 0x30 else {
            throw SigningCertificateError.notACertificate("basicConstraints is not a sequence")
        }
        let children = try sequence.children()
        guard let first = children.first, first.tag == 0x01 else { return false }
        return first.content.first != 0
    }

    /// The commonName attribute of a Name, which is a SEQUENCE of RDN SETs.
    private static func commonName(in name: DERElement) throws -> String? {
        for rdn in try name.children() {
            for attribute in try rdn.children() {
                let parts = try attribute.children()
                if parts.count == 2, parts[0].tag == 0x06, parts[0].content == OID.commonName {
                    return String(decoding: parts[1].content, as: UTF8.self)
                }
            }
        }
        return nil
    }

    /// The `<machine>` of the first `convivy://signer/` URI in the subjectAltName.
    private static func machine(in value: [UInt8]?) throws -> String? {
        guard let value else { return nil }
        let (names, _) = try DERElement.split(value)
        guard names.tag == 0x30 else {
            throw SigningCertificateError.notACertificate("subjectAltName is not a list")
        }
        let prefix = "convivy://signer/"
        for name in try names.children() where name.tag == 0x86 {
            let uri = String(decoding: name.content, as: UTF8.self)
            if uri.hasPrefix(prefix) { return String(uri.dropFirst(prefix.count)) }
        }
        return nil
    }

    /// A UTCTime (`YYMMDDHHMMSSZ`, two-digit years 50 to 99 mean 19xx) or a
    /// GeneralizedTime (`YYYYMMDDHHMMSSZ`), both in UTC.
    private static func time(_ element: DERElement) throws -> Date {
        let text = element.content
        let yearWidth: Int
        switch element.tag {
        case 0x17: yearWidth = 2
        case 0x18: yearWidth = 4
        default: throw SigningCertificateError.notACertificate("a validity time is not a UTC time")
        }
        // Digits for the year, then month to second in pairs, then the Z.
        guard text.count == yearWidth + 11, text.last == UInt8(ascii: "Z") else {
            throw SigningCertificateError.notACertificate("a validity time is not a UTC time")
        }
        let yearDigits = try digitValue(text[0..<yearWidth])
        let year: Int
        if yearWidth == 2 {
            year = yearDigits < 50 ? 2000 + yearDigits : 1900 + yearDigits
        } else {
            year = yearDigits
        }
        // month, day, hour, minute, second
        let pairs = try stride(from: yearWidth, to: text.count - 1, by: 2).map { start in
            try digitValue(text[start..<start + 2])
        }
        let (month, day, hour, minute, second) = (pairs[0], pairs[1], pairs[2], pairs[3], pairs[4])
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        // Calendar rolls month 13 or February 30 into another date rather than
        // refusing it, so the date must read back as the components it was built from.
        guard let date = utc.date(from: components) else {
            throw SigningCertificateError.notACertificate("a validity time is out of range")
        }
        let back = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == year, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute, back.second == second else {
            throw SigningCertificateError.notACertificate("a validity time is out of range")
        }
        return date
    }

    /// The value of ASCII digits only. A sign or any other byte is refused, where
    /// `Int(_:)` would accept `+1` and `-1`.
    private static func digitValue(_ digits: ArraySlice<UInt8>) throws -> Int {
        var value = 0
        for byte in digits {
            guard (0x30...0x39).contains(byte) else {
                throw SigningCertificateError.notACertificate("a validity time has non-digit characters")
            }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }
}

/// One DER element: its tag, its content bytes and its whole encoding. Arrays,
/// not `Data`, so every index starts at zero.
private struct DERElement {
    let tag: UInt8
    let content: [UInt8]
    let encoding: [UInt8]

    /// Splits the first element off `bytes` and returns it with the bytes after
    /// it. Indefinite lengths and lengths over four octets are refused.
    static func split(_ bytes: [UInt8]) throws -> (DERElement, [UInt8]) {
        guard bytes.count >= 2 else {
            throw SigningCertificateError.notACertificate("a DER element is truncated")
        }
        var length = Int(bytes[1])
        var header = 2
        if bytes[1] & 0x80 != 0 {
            let octets = Int(bytes[1] & 0x7F)
            guard (1...4).contains(octets), bytes.count >= 2 + octets else {
                throw SigningCertificateError.notACertificate("a DER length is unsupported")
            }
            length = bytes[2..<2 + octets].reduce(0) { $0 << 8 | Int($1) }
            header += octets
        }
        guard length <= bytes.count - header else {
            throw SigningCertificateError.notACertificate("a DER length runs past the end")
        }
        let end = header + length
        let element = DERElement(tag: bytes[0],
                                 content: Array(bytes[header..<end]),
                                 encoding: Array(bytes[0..<end]))
        return (element, Array(bytes[end...]))
    }

    /// The elements packed in this element's content, in order.
    func children() throws -> [DERElement] {
        var elements: [DERElement] = []
        var rest = content
        while !rest.isEmpty {
            let (element, after) = try DERElement.split(rest)
            elements.append(element)
            rest = after
        }
        return elements
    }
}
