import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL

/// Generates and persists a local Root CA, then mints per-host leaf certificates
/// signed by it so the proxy can terminate TLS as any origin (MITM).
///
/// The Root CA must be installed and trusted by the client (Phase 3 UX) for
/// interception to succeed without certificate warnings.
public final class CertificateAuthority: @unchecked Sendable {

    /// PEM of the Root CA certificate (the file the user must trust).
    public let rootCertificatePEM: String
    /// On-disk location of the exported Root CA certificate (`rootCA.pem`).
    public let rootCertificateURL: URL
    /// On-disk DER copy (`rootCA.crt`) — convenient for installing on devices.
    public let rootCertificateCRTURL: URL
    /// DER bytes of the Root CA certificate (served to devices for install).
    public let rootCertificateDER: Data

    private let caCertificate: Certificate
    private let caPrivateKey: Certificate.PrivateKey
    private let caName: DistinguishedName
    private let nioCACertificate: NIOSSLCertificate

    private var contextCache: [String: NIOSSLContext] = [:]
    private let lock = NSLock()

    private init(certificate: Certificate,
                 privateKey: Certificate.PrivateKey,
                 certificateURL: URL) throws {
        self.caCertificate = certificate
        self.caPrivateKey = privateKey
        // Leaves must name the CA exactly as its certificate does, so take the
        // issuer name from the loaded certificate (which may predate a rename).
        self.caName = certificate.subject
        self.rootCertificateURL = certificateURL
        self.rootCertificatePEM = try certificate.serializeAsPEM().pemString
        let nioCert = try NIOSSLCertificate(bytes: Array(rootCertificatePEM.utf8), format: .pem)
        self.nioCACertificate = nioCert

        let der = Data(try nioCert.toDERBytes())
        self.rootCertificateDER = der
        let crtURL = certificateURL.deletingLastPathComponent().appendingPathComponent("rootCA.crt")
        try? der.write(to: crtURL)
        self.rootCertificateCRTURL = crtURL
    }

    // MARK: - Bootstrap

    /// Loads the Root CA from `directoryURL`, generating and persisting a new one
    /// on first run. Files: `rootCA.pem` (certificate) and `rootCA.key.pem` (key).
    public static func generateOrLoad(directoryURL: URL) throws -> CertificateAuthority {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let certURL = directoryURL.appendingPathComponent("rootCA.pem")
        let keyURL = directoryURL.appendingPathComponent("rootCA.key.pem")
        let name = try Self.rootName()

        if let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
           let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8),
           let certificate = try? Certificate(pemEncoded: certPEM),
           let p256 = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM) {
            return try CertificateAuthority(certificate: certificate,
                                            privateKey: Certificate.PrivateKey(p256),
                                            certificateURL: certURL)
        }

        // Generate fresh.
        let p256 = P256.Signing.PrivateKey()
        let privateKey = Certificate.PrivateKey(p256)
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(3_650 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: privateKey
        )

        let certPEM = try certificate.serializeAsPEM().pemString
        try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
        try p256.pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)

        return try CertificateAuthority(certificate: certificate,
                                        privateKey: privateKey,
                                        certificateURL: certURL)
    }

    private static func rootName() throws -> DistinguishedName {
        try DistinguishedName {
            CommonName("Hachidori Root CA")
            OrganizationName("Hachidori")
        }
    }

    // MARK: - Per-host leaf certificates

    /// Leaf validity. Apple platforms reject TLS server certificates whose
    /// NotBefore→NotAfter span exceeds 825 days (iOS 13+) and, for stricter
    /// profiles, 398 days — so keep the whole window (including the one-day
    /// backdate for clock skew) comfortably inside 398 days.
    static let leafBackdate: TimeInterval = 86_400
    static let leafLifetime: TimeInterval = 390 * 86_400

    /// Mint a leaf certificate for `host` signed by the Root CA.
    func makeLeafCertificate(host: String, key: Certificate.PrivateKey, now: Date = Date()) throws -> Certificate {
        let subject = try DistinguishedName { CommonName(host) }
        let san: GeneralName = Self.ipv4Bytes(host).map { .ipAddress(ASN1OctetString(contentBytes: $0)) }
            ?? .dnsName(host)
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-Self.leafBackdate),
            notValidAfter: now.addingTimeInterval(Self.leafLifetime),
            issuer: caName,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
            },
            issuerPrivateKey: caPrivateKey
        )
    }

    /// Dotted-quad IPv4 → 4 bytes, or nil when `host` is a DNS name.
    static func ipv4Bytes(_ host: String) -> ArraySlice<UInt8>? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let n = UInt8(part) else { return nil }
            bytes.append(n)
        }
        return bytes[...]
    }

    /// A cached TLS server context presenting a freshly-signed leaf for `host`.
    public func serverContext(host: String) throws -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        if let cached = contextCache[host] { return cached }

        let leafP256 = P256.Signing.PrivateKey()
        let leaf = try makeLeafCertificate(host: host, key: Certificate.PrivateKey(leafP256))

        let leafPEM = try leaf.serializeAsPEM().pemString
        let nioLeaf = try NIOSSLCertificate(bytes: Array(leafPEM.utf8), format: .pem)
        let nioKey = try NIOSSLPrivateKey(bytes: Array(leafP256.pemRepresentation.utf8), format: .pem)

        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioLeaf), .certificate(nioCACertificate)],
            privateKey: .privateKey(nioKey)
        )
        config.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)
        contextCache[host] = context
        return context
    }

    // MARK: - iOS configuration profile

    /// An iOS `.mobileconfig` profile embedding the Root CA, so a device can
    /// install it in one step (the user still enables full trust afterwards).
    public func mobileConfigData() -> Data {
        let certBase64 = rootCertificateDER.base64EncodedString()
        let certUUID = UUID().uuidString
        let profileUUID = UUID().uuidString
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadType</key><string>com.apple.security.root</string>
                    <key>PayloadVersion</key><integer>1</integer>
                    <key>PayloadIdentifier</key><string>io.hachidori.ca.\(certUUID)</string>
                    <key>PayloadUUID</key><string>\(certUUID)</string>
                    <key>PayloadDisplayName</key><string>Hachidori Root CA</string>
                    <key>PayloadCertificateFileName</key><string>HachidoriCA.cer</string>
                    <key>PayloadContent</key>
                    <data>\(certBase64)</data>
                </dict>
            </array>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadIdentifier</key><string>io.hachidori.profile.\(profileUUID)</string>
            <key>PayloadUUID</key><string>\(profileUUID)</string>
            <key>PayloadDisplayName</key><string>Hachidori CA</string>
            <key>PayloadDescription</key><string>Installs the Hachidori Root CA for HTTPS debugging.</string>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }
}
