import XCTest
import Crypto
import X509
import SwiftASN1
@testable import ProxyCore

final class CertificateAuthorityTests: XCTestCase {

    private func makeCA() throws -> CertificateAuthority {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hachidori-ca-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try CertificateAuthority.generateOrLoad(directoryURL: dir)
    }

    /// Apple platforms refuse TLS server certs valid for more than 825 days
    /// (and 398 days under newer policies); the old 1-day backdate + 825 days = 826 broke iOS.
    func testLeafValidityFitsApplePolicy() throws {
        let ca = try makeCA()
        let leaf = try ca.makeLeafCertificate(host: "example.com",
                                              key: Certificate.PrivateKey(P256.Signing.PrivateKey()))
        let days = leaf.notValidAfter.timeIntervalSince(leaf.notValidBefore) / 86_400
        XCTAssertLessThanOrEqual(days, 398, "leaf validity must be ≤ 398 days (was \(days))")
        XCTAssertLessThan(leaf.notValidBefore, Date(), "leaf should be backdated for clock skew")
    }

    func testLeafHasServerAuthAndDNSSAN() throws {
        let ca = try makeCA()
        let leaf = try ca.makeLeafCertificate(host: "api.example.com",
                                              key: Certificate.PrivateKey(P256.Signing.PrivateKey()))
        let eku = try XCTUnwrap(try leaf.extensions.extendedKeyUsage)
        XCTAssertTrue(eku.contains(.serverAuth))
        let san = try XCTUnwrap(try leaf.extensions.subjectAlternativeNames)
        XCTAssertTrue(san.contains(.dnsName("api.example.com")))
        XCTAssertEqual(try leaf.extensions.basicConstraints, .notCertificateAuthority)
    }

    func testIPLiteralHostGetsIPAddressSAN() throws {
        let ca = try makeCA()
        let leaf = try ca.makeLeafCertificate(host: "192.168.1.10",
                                              key: Certificate.PrivateKey(P256.Signing.PrivateKey()))
        let san = try XCTUnwrap(try leaf.extensions.subjectAlternativeNames)
        XCTAssertTrue(san.contains(.ipAddress(ASN1OctetString(contentBytes: [192, 168, 1, 10]))))
        XCTAssertFalse(san.contains(.dnsName("192.168.1.10")))
    }

    func testRootCAIsAValidCA() throws {
        let ca = try makeCA()
        let root = try Certificate(pemEncoded: ca.rootCertificatePEM)
        XCTAssertEqual(try root.extensions.basicConstraints, .isCertificateAuthority(maxPathLength: nil))
        let ku = try XCTUnwrap(try root.extensions.keyUsage)
        XCTAssertTrue(ku.keyCertSign)
    }
}
