import XCTest
@testable import TutunSystem

final class CoreLogFilterTests: XCTestCase {
    func testDropsPerConnectionErrorsWithAndWithoutColor() {
        let noise = [
            "ERROR [2724204634 2ms] connection: open connection to 192.0.2.10:1935 using outbound/direct[direct]: dial tcp 192.0.2.10:1935: no route to host",
            "\u{1B}[31mERROR\u{1B}[0m [\u{1B}[38;5;106m2724204634\u{1B}[0m 2ms] connection: open connection to 192.0.2.10:443 using outbound/socks[proxy]: i/o timeout",
            "ERROR connection: listen packet connection using  using outbound/direct[direct]: listen udp4 :0: can't assign requested address",
            "ERROR [1 0ms] connection: connection download closed: raw read: can't assign requested address",
            // Настоящий вид с --disable-color (журнал 10.11.2026 после службы 2.6) — его первая версия фильтра пропускала.
            "ERROR[0575] [2942370845 5.0s] connection: open connection to 192.0.2.10:443 using outbound/direct[direct]: dial tcp 192.0.2.10:443: i/o timeout",
            "WARN[0012] connection: connection upload closed: close tcp 192.0.2.1:1->192.0.2.2:2: shutdown: can't assign requested address",
            // С меткой времени sing-box впереди (старые конфиги с timestamp: true).
            "+0300 2026-11-10 12:13:51 ERROR [2724204634 2ms] connection: open connection to 192.0.2.10:1935 using outbound/direct[direct]: no route to host",
        ]
        for line in noise { XCTAssertTrue(CoreLogFilter.isConnectionNoise(line), line) }
    }

    func testKeepsServiceLevelProblems() {
        let keep = [
            "ERROR network: missing default interface",
            "ERROR[0000] network: missing default interface",
            "FATAL[0000] start service: initialize inbound/tun[tun]: configure tun interface: device busy",
            "ERROR inbound/tun[tun]: batch read packet: socket operation on non-socket",
            "FATAL start service: start inbound/tun[tun]: configure tun interface: operation not permitted",
            "2026/11/10 12:30:35.197432 [Warning] core: Xray 26.10.31 started",
            "WARN outbound/direct[direct]: connection: something about the outbound itself",
        ]
        for line in keep { XCTAssertFalse(CoreLogFilter.isConnectionNoise(line), line) }
    }
}
