import XCTest
@testable import TutunCore

final class UpdateTrustTests: XCTestCase {
    private func fixture(_ root: URL, _ name: String, id: String, sign: Bool = true) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let mac = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: mac.appendingPathComponent("Fixture").path)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--sign", "-", app.path]
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
        }
        return app
    }

    func testAdHocInstallAcceptsIntactTutunButNotOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try fixture(root, "Installed", id: "local.tutun.app")
        XCTAssertThrowsError(try UpdateTrust.team(at: installed))
        XCTAssertEqual(UpdateTrust.policy(for: installed), .adHoc)
        let fresh = try fixture(root, "Fresh", id: "local.tutun.app")
        XCTAssertNoThrow(try UpdateTrust.validate(fresh, against: installed))
        // Чужое приложение, неподписанное и испорченное после подписи — отказ.
        XCTAssertThrowsError(try UpdateTrust.validate(try fixture(root, "Other", id: "com.example.other"), against: installed))
        XCTAssertThrowsError(try UpdateTrust.validate(try fixture(root, "Unsigned", id: "local.tutun.app", sign: false), against: installed))
        try Data("tampered".utf8).write(to: fresh.appendingPathComponent("Contents/MacOS/Fixture"))
        XCTAssertThrowsError(try UpdateTrust.validate(fresh, against: installed))
    }
    func testUnsignedOrMissingApplicationIsRejected() {
        XCTAssertThrowsError(try UpdateTrust.team(at: URL(fileURLWithPath: "/tmp/no-such-tutun-app-87125.app")))
    }
}
