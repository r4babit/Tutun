import Foundation
import IOKit
import IOKit.pwr_mgt
import Network

/// Power notifications work in a launch daemon, without a running GUI session.
/// Must be started/stopped on the main queue, which the daemon services with dispatchMain().
public final class SystemWakeObserver {
    private var port: IONotificationPortRef?
    private var connection: io_connect_t = 0
    private var notifier: io_object_t = 0
    private let onSleep: () -> Void
    private let onWake: () -> Void

    public init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep; self.onWake = onWake
    }

    public func start() -> Bool {
        guard connection == 0 else { return true }
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { ref, _, message, argument in
            guard let ref else { return }
            let observer = Unmanaged<SystemWakeObserver>.fromOpaque(ref).takeUnretainedValue()
            // IOMessage.h: iokit_common_msg(0x280/0x270/0x300). C macros are not imported by Swift.
            switch message {
            case 0xe0000280:
                observer.onSleep()
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            case 0xe0000270:
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            case 0xe0000300: observer.onWake()
            default: break
            }
        }, &notifier)
        guard connection != 0, let port else { stop(); return false }
        IONotificationPortSetDispatchQueue(port, .main)
        return true
    }

    public func stop() {
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }

    deinit { stop() }
}

/// Ignore virtual TUN interfaces so our own tunnel restarts don't cause a restart loop.
public final class PhysicalNetworkObserver {
    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
    public init(queue: DispatchQueue, onChange: @escaping (String) -> Void) {
        monitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.name):\($0.index)" }.sorted().joined(separator: ",")
            let gateways = path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
            onChange("\(path.status)|\(interfaces)|\(gateways)|v4=\(path.supportsIPv4)|v6=\(path.supportsIPv6)")
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}
