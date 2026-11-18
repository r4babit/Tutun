import XCTest
@testable import TutunSystem

final class ConnectionRecoveryTests: XCTestCase {
    final class Clock {
        var actions: [() -> Void] = []
        var cancellations = 0
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void) {
            XCTAssertEqual(delay, 2)
            actions.append(action)
            return { self.cancellations += 1 }
        }
        // Run even cancelled work to exercise the race with DispatchWorkItem execution.
        func fire(_ index: Int) { actions[index]() }
    }

    func testWakeRestartsActiveConnectionOnceAndReenablesHealth() {
        let clock = Clock(); var reasons: [String] = []
        let recovery = ConnectionRecovery(schedule: clock.schedule) { reasons.append($0) }
        recovery.setActive(true)
        recovery.willSleep()
        XCTAssertFalse(recovery.canCheckHealth)
        recovery.didWake()
        XCTAssertTrue(recovery.isPending)
        XCTAssertFalse(recovery.canCheckHealth)
        clock.fire(0)
        clock.fire(0)
        XCTAssertEqual(reasons, ["Mac вышел из сна"])
        XCTAssertTrue(recovery.canCheckHealth)
    }

    func testWakeDoesNotConnectWhenUserHadDisconnectedBeforeSleep() {
        let clock = Clock()
        let recovery = ConnectionRecovery(schedule: clock.schedule) { _ in XCTFail("Unexpected reconnect") }
        recovery.willSleep(); recovery.didWake()
        XCTAssertTrue(clock.actions.isEmpty)
        XCTAssertFalse(recovery.canCheckHealth)
    }

    func testDisconnectDuringWakeDelayCancelsEvenAlreadyEnqueuedAction() {
        let clock = Clock()
        let recovery = ConnectionRecovery(schedule: clock.schedule) { _ in XCTFail("User disconnect must win") }
        recovery.setActive(true); recovery.didWake()
        recovery.setActive(false)
        clock.fire(0)
        XCTAssertFalse(recovery.isPending)
        XCTAssertEqual(clock.cancellations, 1)
    }

    func testWakeAndNetworkBurstCoalesceIntoOneReconnect() {
        let clock = Clock(); var count = 0
        let recovery = ConnectionRecovery(schedule: clock.schedule) { _ in count += 1 }
        recovery.setActive(true)
        recovery.networkChanged("wifi:gateway1")
        recovery.didWake()
        recovery.networkChanged("wifi:gateway2")
        recovery.didWake()
        XCTAssertEqual(clock.actions.count, 3)
        clock.actions.forEach { $0() }
        XCTAssertEqual(count, 1)
    }

    func testInitialAndIdenticalNetworkSnapshotsDoNotRestartTunnel() {
        let clock = Clock(); var count = 0
        let recovery = ConnectionRecovery(schedule: clock.schedule) { _ in count += 1 }
        recovery.setActive(true)
        recovery.networkChanged("wifi")
        recovery.networkChanged("wifi")
        XCTAssertTrue(clock.actions.isEmpty)
        recovery.networkChanged("ethernet")
        clock.fire(0)
        XCTAssertEqual(count, 1)
    }

    func testSecondSleepInvalidatesPendingRecoveryAndOldHealthEpoch() {
        let clock = Clock(); var count = 0
        let recovery = ConnectionRecovery(schedule: clock.schedule) { _ in count += 1 }
        recovery.setActive(true)
        let oldEpoch = recovery.epoch
        recovery.didWake(); recovery.willSleep()
        XCTAssertNotEqual(recovery.epoch, oldEpoch)
        clock.fire(0)
        XCTAssertEqual(count, 0)
        recovery.didWake(); clock.fire(1)
        XCTAssertEqual(count, 1)
    }

    func testManualStartSupersedesScheduledRecovery() {
        let clock = Clock()
        let recovery = ConnectionRecovery(schedule: clock.schedule) { _ in XCTFail("Old recovery must not replace new plan") }
        recovery.setActive(true); recovery.didWake()
        recovery.setActive(true)
        clock.fire(0)
        XCTAssertTrue(recovery.canCheckHealth)
    }

    func testNetworkChangesWhileStoppedDoNotCauseLaterStaleReconnect() {
        let clock = Clock()
        let recovery = ConnectionRecovery(schedule: clock.schedule) { _ in XCTFail("Unexpected reconnect") }
        recovery.networkChanged("wifi")
        recovery.networkChanged("offline")
        recovery.setActive(true)
        XCTAssertTrue(clock.actions.isEmpty)
    }
}
