import CryptoKit
import XCTest
@testable import TutunCore

final class ReleaseSignatureTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    var pub: String { key.publicKey.rawRepresentation.base64EncodedString() }
    func sign(_ data: Data) throws -> String { try key.signature(for: data).base64EncodedString() }

    func testSequenceSurvivesDecodingAndRejectsRollback() throws {
        let data = Data(#"{"version":"1.2","sequence":12}"#.utf8)
        let manifest = try XCTUnwrap(ReleaseManifest.verified(data, signatureBase64: try sign(data), publicKeyBase64: pub))
        XCTAssertTrue(manifest.accepts(version: "1.2", highestSequence: 12))
        XCTAssertFalse(manifest.accepts(version: "1.2", highestSequence: 13))
        XCTAssertFalse(manifest.accepts(version: "1.3", highestSequence: 0))
        let legacy = ReleaseManifest(version: "1.2")
        XCTAssertTrue(legacy.accepts(version: "1.2", highestSequence: 0))
        XCTAssertFalse(legacy.accepts(version: "1.2", highestSequence: 1))
    }

    func testOnlyUntouchedFileSignedByTheKeyPasses() throws {
        let archive = Data("Tutun.zip bytes".utf8)
        let signature = try sign(archive)
        XCTAssertTrue(ReleaseSignature.verify(archive, signatureBase64: signature + "\n", publicKeyBase64: pub))
        XCTAssertFalse(ReleaseSignature.verify(archive + Data([0]), signatureBase64: signature, publicKeyBase64: pub))
        // Чужой ключ (взломанный аккаунт GitHub подписать не может) и мусор вместо подписи.
        let other = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(ReleaseSignature.verify(archive, signatureBase64: try other.signature(for: archive).base64EncodedString(), publicKeyBase64: pub))
        XCTAssertFalse(ReleaseSignature.verify(archive, signatureBase64: "не подпись", publicKeyBase64: pub))
        XCTAssertFalse(ReleaseSignature.verify(archive, signatureBase64: signature, publicKeyBase64: "AAAA"))
    }

    func testEmbeddedKeyIsAValidEd25519Key() throws {
        let raw = try XCTUnwrap(Data(base64Encoded: ReleaseSignature.publicKeyBase64))
        XCTAssertEqual(raw.count, 32)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
    }

    func testManifestRevokesOldAndBlockedVersionsOnly() throws {
        let m = ReleaseManifest(version: "1.3.0", minimumVersion: "1.1.0", blocked: ["1.2.1", "v1.2.3"])
        XCTAssertTrue(m.revokes("1.0.9"))      // старше минимальной
        XCTAssertFalse(m.revokes("1.1.0"))
        XCTAssertTrue(m.revokes("1.2.1"))      // отозвана поимённо
        XCTAssertTrue(m.revokes("1.2.3"))
        XCTAssertFalse(m.revokes("1.2.2"))
        XCTAssertFalse(m.revokes("1.3.0"))     // уже последняя — обновляться некуда
        XCTAssertFalse(m.revokes("1.4.0"))
        XCTAssertFalse(ReleaseManifest(version: "1.3.0").revokes("1.0.0"))
    }

    func testManifestIsReadOnlyWithValidSignature() throws {
        let data = Data(#"{"version":"2.0.0","minimumVersion":"1.5.0"}"#.utf8)
        let good = try XCTUnwrap(ReleaseManifest.verified(data, signatureBase64: try sign(data), publicKeyBase64: pub))
        XCTAssertEqual(good, ReleaseManifest(version: "2.0.0", minimumVersion: "1.5.0"))
        let forged = Data(#"{"version":"2.0.0","minimumVersion":"9.9.9"}"#.utf8)
        XCTAssertNil(ReleaseManifest.verified(forged, signatureBase64: try sign(data), publicKeyBase64: pub))
    }
}
