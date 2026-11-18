import XCTest
@testable import TutunCore
import TutunShared
final class SubscriptionTransportTests: XCTestCase {
    func testRedirectCannotDowngradeOrForwardDeviceDataAcrossOrigins() {
        let original = URL(string: "https://provider.invalid/sub")!
        var request = URLRequest(url: URL(string: "https://cdn.invalid/file")!)
        request.setValue("fixture-secret", forHTTPHeaderField: "X-HWID")
        request.setValue("Mac", forHTTPHeaderField: "X-Device-Model")
        request.setValue("Tutun", forHTTPHeaderField: "User-Agent")
        let stripped = SubscriptionTransport.redirect(request, from: original)!
        XCTAssertNil(stripped.value(forHTTPHeaderField: "X-HWID"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "X-Device-Model"))
        XCTAssertEqual(stripped.value(forHTTPHeaderField: "User-Agent"), "Tutun")
        request.url = URL(string: "https://PROVIDER.invalid:443/next")!
        XCTAssertEqual(SubscriptionTransport.redirect(request, from: original)?.value(forHTTPHeaderField: "X-HWID"), "fixture-secret")
        request.url = URL(string: "https://provider.invalid:8443/next")!
        XCTAssertNil(SubscriptionTransport.redirect(request, from: original)?.value(forHTTPHeaderField: "X-HWID"))
        request.url = URL(string: "http://provider.invalid/plain")!
        XCTAssertNil(SubscriptionTransport.redirect(request, from: original))
        XCTAssertFalse(SubscriptionTransport.secure(URL(string: "http://provider.invalid")!))
    }

    func testHttpOnlyWithToggleAndNeverWithDeviceData() {
        let plain = URL(string: "http://panel.invalid/sub")!
        XCTAssertFalse(SubscriptionTransport.allowed(plain, allowHTTP: false))
        XCTAssertTrue(SubscriptionTransport.allowed(plain, allowHTTP: true))
        XCTAssertFalse(SubscriptionTransport.allowed(URL(string: "ftp://panel.invalid/sub")!, allowHTTP: true))
        let original = URL(string: "https://panel.invalid/sub")!
        var request = URLRequest(url: URL(string: "http://panel.invalid/sub2")!)
        request.setValue("fixture-secret", forHTTPHeaderField: "X-HWID")
        request.setValue("Tutun", forHTTPHeaderField: "User-Agent")
        XCTAssertNil(SubscriptionTransport.redirect(request, from: original, allowHTTP: false))
        let down = SubscriptionTransport.redirect(request, from: original, allowHTTP: true)!
        XCTAssertNil(down.value(forHTTPHeaderField: "X-HWID"))
        XCTAssertEqual(down.value(forHTTPHeaderField: "User-Agent"), "Tutun")
        // Тот же http-адрес: ID устройства всё равно не уходит.
        let same = SubscriptionTransport.redirect(request, from: plain, allowHTTP: true)!
        XCTAssertNil(same.value(forHTTPHeaderField: "X-HWID"))
    }

    func testAllowHttpDefaultsOffAndSurvivesDecoding() throws {
        XCTAssertFalse(AppSettings().allowHttpSubscriptions)
        var s = AppSettings(); s.allowHttpSubscriptions = true
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.allowHttpSubscriptions)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.allowHttpSubscriptions)
    }
}
