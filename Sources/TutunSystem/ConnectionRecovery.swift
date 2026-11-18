import Foundation

/// Access only on the supervisor queue. Delays coalesce wake/network events;
/// the epoch also invalidates health results started before sleep or a reconnect.
public final class ConnectionRecovery {
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    public private(set) var epoch: UInt64 = 0
    public private(set) var isSleeping = false
    public private(set) var isPending = false
    private var active = false
    private var network: String?
    private var cancel: (() -> Void)?
    private let schedule: Scheduler
    private let reconnect: (String) -> Void

    public init(schedule: @escaping Scheduler, reconnect: @escaping (String) -> Void) {
        self.schedule = schedule; self.reconnect = reconnect
    }

    public var canCheckHealth: Bool { active && !isSleeping && !isPending }

    public func setActive(_ value: Bool) {
        active = value
        invalidate()
    }

    public func willSleep() {
        isSleeping = true
        invalidate()
    }

    public func didWake() {
        isSleeping = false
        request("Mac вышел из сна")
    }

    public func networkChanged(_ fingerprint: String) {
        let previous = network
        network = fingerprint
        guard let previous, previous != fingerprint else { return }
        request("Изменилась сеть")
    }

    public func request(_ reason: String) {
        guard active, !isSleeping else { return }
        invalidate()
        isPending = true
        let ticket = epoch
        cancel = schedule(2) { [weak self] in
            guard let self, self.active, !self.isSleeping, self.isPending, self.epoch == ticket else { return }
            self.cancel = nil; self.isPending = false
            self.reconnect(reason)
        }
    }

    private func invalidate() {
        epoch &+= 1
        cancel?(); cancel = nil; isPending = false
    }
}
