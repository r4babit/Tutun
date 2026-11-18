import XCTest
import TutunShared

final class TutunSharedTests: XCTestCase {
    func testPublishedExamplesAndPreferenceSchemaStayAligned() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["empty-profile", "demo-profile"] {
            let data = try Data(contentsOf: root.appendingPathComponent("shared/examples/\(name).tutun.json"))
            XCTAssertNoThrow(try ConfigurationProfile.decode(data))
        }
        let data = try Data(contentsOf: root.appendingPathComponent("shared/schemas/tutun-profile-v1.schema.json"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let prefs = try XCTUnwrap(defs["preferences"] as? [String: Any])
        let properties = try XCTUnwrap(prefs["properties"] as? [String: Any])
        let required = try XCTUnwrap(prefs["required"] as? [String])
        let encoded = try JSONEncoder().encode(ConnectionPreferences())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(required), Set(object.keys))
        XCTAssertEqual(Set(properties.keys), Set(object.keys).union(["chainServerID", "activeProfileID"]))
    }

    func testInvalidPreferencesAreRejected() {
        var prefs = ConnectionPreferences()
        prefs.testURL = "file:///tmp/invalid"
        XCTAssertThrowsError(try prefs.validate())
        prefs = .init()
        prefs.healthFailLimit = 0
        XCTAssertThrowsError(try prefs.validate())
    }
    func testEmptyProfileRoundTrip() throws {
        let original = ConfigurationProfile()
        let data = try original.encode()
        XCTAssertEqual(try ConfigurationProfile.decode(data), original)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("showInDock"))
        XCTAssertFalse(text.contains("hwid"))
        XCTAssertFalse(text.contains("launchAtLogin"))
        XCTAssertFalse(text.contains("directApps"))
    }

    func testProfileRejectsUnknownVersionAndFormat() throws {
        let data = try ConfigurationProfile().encode()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        XCTAssertThrowsError(try ConfigurationProfile.decode(JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 1
        object["format"] = "other.product"
        XCTAssertThrowsError(try ConfigurationProfile.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testProfileRejectsDuplicatesAndDanglingReferences() throws {
        let server = Server(id: "example", name: "Example", proto: "socks", host: "127.0.0.1", port: 1080,
                            transport: "tcp", outboundJSON: #"{"protocol":"socks"}"#)
        XCTAssertThrowsError(try ConfigurationProfile(servers: [server, server]).validate())
        var profile = ConfigurationProfile(servers: [server])
        profile.preferences.chainServerID = "missing"
        XCTAssertThrowsError(try profile.validate())
        profile.preferences.chainServerID = nil
        profile.preferences.activeProfileID = UUID()
        XCTAssertThrowsError(try profile.validate())
    }

    func testProfilePreservesServersSubscriptionsAndDates() throws {
        var sub = Subscription(name: "Example", url: "https://example.invalid/subscription")
        sub.lastUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        let server = Server(id: "example", name: "Example", proto: "socks", host: "127.0.0.1", port: 1080,
                            transport: "tcp", outboundJSON: #"{"protocol":"socks"}"#, subscriptionID: sub.id)
        let profile = ConfigurationProfile(servers: [server], subscriptions: [sub])
        XCTAssertEqual(try ConfigurationProfile.decode(profile.encode()), profile)
    }
}
