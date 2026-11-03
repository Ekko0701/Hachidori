import Foundation
import Crypto
import X509
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
                 name: DistinguishedName,
                 certificateURL: URL) throws {
        self.caCertificate = certificate
        self.caPrivateKey = privateKey
        self.caName = name
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
                                            name: name,
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
                                        name: name,
                                        certificateURL: certURL)
    }

    private static func rootName() throws -> DistinguishedName {
        try DistinguishedName {
            CommonName("ProxyBoy Root CA")
            OrganizationName("ProxyBoy")
        }
    }

    // MARK: - Per-host leaf certificates

    /// A cached TLS server context presenting a freshly-signed leaf for `host`.
    public func serverContext(host: String) throws -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        if let cached = contextCache[host] { return cached }

        let leafP256 = P256.Signing.PrivateKey()
        let leafKey = Certificate.PrivateKey(leafP256)
        let subject = try DistinguishedName { CommonName(host) }
        let now = Date()

        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: leafKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(825 * 86_400),
            issuer: caName,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
            },
            issuerPrivateKey: caPrivateKey
        )

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
                    <key>PayloadIdentifier</key><string>io.proxyboy.ca.\(certUUID)</string>
                    <key>PayloadUUID</key><string>\(certUUID)</string>
                    <key>PayloadDisplayName</key><string>ProxyBoy Root CA</string>
                    <key>PayloadCertificateFileName</key><string>ProxyBoyCA.cer</string>
                    <key>PayloadContent</key>
                    <data>\(certBase64)</data>
                </dict>
            </array>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadIdentifier</key><string>io.proxyboy.profile.\(profileUUID)</string>
            <key>PayloadUUID</key><string>\(profileUUID)</string>
            <key>PayloadDisplayName</key><string>ProxyBoy CA</string>
            <key>PayloadDescription</key><string>Installs the ProxyBoy Root CA for HTTPS debugging.</string>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }
}
