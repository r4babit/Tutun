import XCTest
@testable import TutunShared

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.set(.system) }

    func testTranslatesWithArguments() {
        let name = "Германия"
        L10n.set(.en)
        XCTAssertEqual(tr("Подключено"), "Connected")
        XCTAssertEqual(tr("Сервер «\(name)»"), "Server “Германия”")
        XCTAssertEqual(tr("Восстановлено: серверов \(3), подписок \(1)"), "Restored: 3 servers, 1 subscriptions")
        XCTAssertEqual(L10n.servers(1), "1 server")
        L10n.set(.uk)
        XCTAssertEqual(tr("Подключено"), "Підключено")
        XCTAssertEqual(L10n.servers(3), "3 сервери")
        XCTAssertEqual(L10n.servers(11), "11 серверів")
        L10n.set(.ru)
        XCTAssertEqual(tr("Сервер «\(name)»"), "Сервер «Германия»")
        XCTAssertEqual(L10n.servers(22), "22 сервера")
    }

    func testUnknownAndDynamicStrings() {
        L10n.set(.en)
        XCTAssertEqual(tr("Строка без перевода \(5)"), "Строка без перевода 5")
        XCTAssertEqual(trDynamic("Нет конфига"), "No config")
        XCTAssertEqual(trDynamic("xray не принял конфиг: bad tag"), "xray rejected the config: bad tag")
    }

    func testPositionalArguments() {
        XCTAssertEqual(L10n.fill("%2$@ — %1$@ (%@)", ["a", "b"]), "b — a (a)")
        XCTAssertEqual(L10n.fill("100% %@", ["x"]), "100% x")
    }

    func testEveryTranslationKeepsPlaceholders() {
        let ph = try! NSRegularExpression(pattern: #"%(\d\$)?@"#)
        func count(_ s: String) -> Int { ph.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
        for (ru, t) in L10nStrings.table {
            XCTAssertEqual(t.count, AppLanguage.translated.count, ru)
            for s in t { XCTAssertEqual(count(s), count(ru), "\(ru) → \(s)") }
        }
    }

    func testAllLanguagesHaveCountryNamesAndPlurals() {
        for l in AppLanguage.allCases where l != .system {
            L10n.set(l)
            XCTAssertNotEqual(Server.countryName("DE"), "DE", l.rawValue)
            XCTAssertFalse(L10n.servers(5).isEmpty)
        }
        L10n.set(.ko)
        XCTAssertEqual(tr("Подключено"), L10nStrings.table["Подключено"]![AppLanguage.translated.firstIndex(of: .ko)!])
        XCTAssertEqual(L10n.servers(3), "서버 3개")
    }
}
