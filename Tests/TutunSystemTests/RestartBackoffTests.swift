import XCTest
@testable import TutunSystem

final class RestartBackoffTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstRestartIsImmediateThenGapsDoubleUpToCap() {
        var b = RestartBackoff(base: 60, cap: 600)
        XCTAssertTrue(b.attempt(now: t0))
        // Старый цикл: следующая попытка через ~50 с — теперь отложена.
        XCTAssertFalse(b.attempt(now: t0 + 50))
        XCTAssertTrue(b.attempt(now: t0 + 60))
        XCTAssertFalse(b.attempt(now: t0 + 60 + 119))
        XCTAssertTrue(b.attempt(now: t0 + 60 + 120))
        XCTAssertEqual(b.nextAllowed, t0 + 180 + 240)
        var gaps: [TimeInterval] = []
        for _ in 0..<4 {
            let now = b.nextAllowed
            XCTAssertTrue(b.attempt(now: now))
            gaps.append(b.nextAllowed.timeIntervalSince(now))
        }
        XCTAssertEqual(gaps, [480, 600, 600, 600])
    }

    func testRecoveredLinkAllowsImmediateRestartAgain() {
        var b = RestartBackoff(base: 60, cap: 600)
        XCTAssertTrue(b.attempt(now: t0))
        XCTAssertTrue(b.attempt(now: t0 + 60))
        XCTAssertFalse(b.attempt(now: t0 + 61))
        b.reset()
        XCTAssertEqual(b.streak, 0)
        XCTAssertTrue(b.attempt(now: t0 + 61))
        XCTAssertEqual(b.nextAllowed, t0 + 61 + 60)
    }

    func testDeniedAttemptsDoNotGrowTheGap() {
        var b = RestartBackoff(base: 60, cap: 600)
        XCTAssertTrue(b.attempt(now: t0))
        for s in stride(from: 1.0, to: 60, by: 10) { XCTAssertFalse(b.attempt(now: t0 + s)) }
        XCTAssertEqual(b.streak, 1)
        XCTAssertEqual(b.nextAllowed, t0 + 60)
    }
}
