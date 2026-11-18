import Foundation
import TutunCore

/// Проверка серверов «по-настоящему»: временное ядро xray (и sing-box для TUIC/Hysteria2-obfs) от имени пользователя
/// открывает свой локальный порт на каждый сервер, через который идёт запрос к тестовому адресу.
/// Эти ядра — из Tutun.app, в режиме «Весь трафик» они идут мимо VPN (правило в sing-box).
enum Tester {
    struct Harness {
        let ports: [String: Int]          // id сервера → локальный socks-порт
        let processes: [Process]
        let dir: URL
        func stop() {
            Tester.stopProcesses(processes)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Ядра всех идущих проверок — чтобы остановить их, когда Tutun закрывается.
    private static let liveLock = NSLock()
    private static var live: [Process] = []

    /// Поднимает временные ядра. Серверы, которые ядро не приняло, выкидываются.
    static func start(_ servers: [Server], settings: AppSettings) async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tutun-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var procs: [Process] = []
        var handedOff = false
        defer {
            if !handedOff {
                stopProcesses(procs)
                try? FileManager.default.removeItem(at: dir)
            }
        }
        var list = servers.filter { LinkParser.rejectReason($0) == nil }
        var lastError = ""
        for _ in 0..<6 {
            guard !list.isEmpty else { break }
            // Порты выдаёт система: зависшее ядро или чужая программа на «нашем» порту не подменят результат.
            let helperCount = list.filter { $0.engine == .singbox }.count
            let free = try freePorts(list.count + helperCount)
            let (xcfg, hcfg, ports) = configs(list, settings: settings, ports: Array(free.prefix(list.count)),
                                              helperPorts: Array(free.dropFirst(list.count)))
            let xPath = dir.appendingPathComponent("x.json")
            try xcfg.write(to: xPath, atomically: true, encoding: .utf8)
            chmod(xPath.path, 0o600)
            let res = Bundle.main.resourcePath ?? ""
            let (code, out) = run(Paths.bundledXray, ["run", "-test", "-c", xPath.path], env: ["XRAY_LOCATION_ASSET": res])
            if code != 0 {
                lastError = out
                if let r = out.range(of: #"tag o(\d+)"#, options: .regularExpression), let i = Int(out[r].dropFirst(5)), list.indices.contains(i) {
                    list.remove(at: i); continue
                }
                break
            }
            if let hcfg {
                let hPath = dir.appendingPathComponent("h.json")
                try hcfg.write(to: hPath, atomically: true, encoding: .utf8)
                chmod(hPath.path, 0o600)
                procs.append(try spawn(Paths.bundledSingBox, ["run", "-c", hPath.path, "-D", dir.path], env: [:]))
            }
            procs.append(try spawn(Paths.bundledXray, ["run", "-c", xPath.path], env: ["XRAY_LOCATION_ASSET": res]))
            // Ждём, пока наши ядра откроют все порты (и проверочные, и вспомогательного sing-box).
            var ready = false
            for _ in 0..<50 {
                try Task.checkCancellation()
                guard procs.allSatisfy(\.isRunning) else { break }
                if free.allSatisfy(tcpOpen) { ready = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard ready, procs.allSatisfy(\.isRunning) else { throw NSError(domain: "Tutun", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("Ядро проверки не открыло порт")]) }
            handedOff = true
            return Harness(ports: ports, processes: procs, dir: dir)
        }
        try? FileManager.default.removeItem(at: dir)
        throw NSError(domain: "Tutun", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("Ядро проверки не запустилось: ") +
            (lastError.split(separator: "\n").last(where: { !$0.contains("[Warning]") }).map(String.init) ?? tr("нет подходящих серверов"))])
    }

    static func configs(_ servers: [Server], settings s: AppSettings, ports inPorts: [Int], helperPorts: [Int]) -> (String, String?, [String: Int]) {
        var inbounds: [[String: Any]] = [], outbounds: [[String: Any]] = [], rules: [[String: Any]] = []
        var ports: [String: Int] = [:]
        var helperIn: [[String: Any]] = [], helperOut: [[String: Any]] = [], helperRules: [[String: Any]] = []
        var k = 0
        for (i, srv) in servers.enumerated() {
            let port = inPorts[i]
            ports[srv.id] = port
            inbounds.append(["tag": "t\(i)", "listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": ["udp": true]])
            var ob: [String: Any]
            if srv.engine == .singbox {
                ob = ["protocol": "socks", "settings": ["servers": [["address": "127.0.0.1", "port": helperPorts[k]]]]]
                helperIn.append(["type": "socks", "tag": "h\(k)", "listen": "127.0.0.1", "listen_port": helperPorts[k]])
                var hob = srv.outbound; hob["tag"] = "ho\(k)"; helperOut.append(hob)
                helperRules.append(["inbound": ["h\(k)"], "outbound": "ho\(k)"])
                k += 1
            } else {
                ob = srv.outbound
                if s.fragment, var ss = ob["streamSettings"] as? [String: Any],
                   ["tcp", "raw", "ws", "grpc", "xhttp", "httpupgrade"].contains(ss["network"] as? String ?? "tcp"),
                   ["vless", "vmess", "trojan", "shadowsocks"].contains(ob["protocol"] as? String ?? "") {
                    var so = ss["sockopt"] as? [String: Any] ?? [:]; so["dialerProxy"] = "fragment"; ss["sockopt"] = so
                    ob["streamSettings"] = ss
                }
            }
            ob["tag"] = "o\(i)"
            outbounds.append(ob)
            rules.append(["inboundTag": ["t\(i)"], "outboundTag": "o\(i)"])
        }
        if s.fragment {
            outbounds.append(["tag": "fragment", "protocol": "freedom",
                              "settings": ["fragment": ["packets": s.fragmentPackets, "length": s.fragmentLength, "interval": s.fragmentInterval]]])
        }
        outbounds.append(["tag": "direct", "protocol": "freedom"])
        let x: [String: Any] = ["log": ["loglevel": "error"], "inbounds": inbounds, "outbounds": outbounds,
                                "routing": ["rules": rules]]
        var h: String?
        if !helperIn.isEmpty {
            helperOut.append(["type": "direct", "tag": "direct"])
            h = LinkParser.toJSON(["log": ["level": "error"], "inbounds": helperIn, "outbounds": helperOut,
                                   "route": ["rules": helperRules, "final": "direct", "auto_detect_interface": true]] as [String: Any])
        }
        return (LinkParser.toJSON(x), h, ports)
    }

    static func session(port: Int, timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port,
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
        ]
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    /// Задержка запроса через сервер, мс; -1 — не ответил.
    static func delay(port: Int, url: String, head: Bool, timeout: TimeInterval) async -> Int {
        guard let u = URL(string: url) else { return -1 }
        let s = session(port: port, timeout: timeout)
        defer { s.invalidateAndCancel() }
        var req = URLRequest(url: u); req.httpMethod = head ? "HEAD" : "GET"
        // Первый запрос прогревает соединение, второй — честная задержка (как «реальная задержка» в v2rayN).
        guard (try? await s.data(for: req)) != nil else { return -1 }
        let start = Date()
        guard let (_, resp) = try? await s.data(for: req), let http = resp as? HTTPURLResponse, http.statusCode < 500 else { return -1 }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Скорость скачивания через сервер, байт/с.
    static func speed(port: Int, seconds: TimeInterval = 12) async -> Double? {
        guard let u = URL(string: "https://speed.cloudflare.com/__down?bytes=50000000") else { return nil }
        let s = session(port: port, timeout: seconds + 10)
        defer { s.invalidateAndCancel() }
        let start = Date()
        guard let (bytes, resp) = try? await s.bytes(from: u), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var count = 0
        do {
            for try await _ in bytes {
                count += 1
                if count % 65536 == 0, Date().timeIntervalSince(start) > seconds { break }
            }
        } catch { if count == 0 { return nil } }
        let dt = Date().timeIntervalSince(start)
        return dt > 0 ? Double(count) / dt : nil
    }

    // MARK: helpers

    private static func stopProcesses(_ processes: [Process]) {
        for p in processes where p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while processes.contains(where: \.isRunning), Date() < deadline { usleep(20_000) }
        for p in processes where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        for p in processes { p.waitUntilExit() }
        liveLock.lock(); live.removeAll { p in processes.contains { $0 === p } }; liveLock.unlock()
    }

    /// При выходе из Tutun: ядра проверки не должны пережить приложение.
    static func stopAll() {
        liveLock.lock(); let all = live; liveLock.unlock()
        stopProcesses(all)
    }

    /// Ядра проверки, оставшиеся от прошлого запуска (Tutun закрыли или переустановили посреди проверки),
    /// и их временные папки. Трогает только процессы текущего пользователя с конфигом из tutun-test-*.
    static func killLeftovers() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-U", String(getuid()), "-f", "/Contents/Resources/(xray|sing-box) run -c .*/tutun-test-"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { p.waitUntilExit() }
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("tutun-test-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    static func spawn(_ exe: String, _ args: [String], env: [String: String]) throws -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        liveLock.lock(); live.append(p); liveLock.unlock()
        return p
    }

    /// Свободные порты 127.0.0.1 от системы (сокеты закрываются сразу, ядро занимает их следом).
    static func freePorts(_ count: Int) throws -> [Int] {
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        var ports: [Int] = []
        for _ in 0..<count {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw NSError(domain: "Tutun", code: 3, userInfo: [NSLocalizedDescriptionKey: tr("Нет свободного порта для проверки")]) }
            fds.append(fd)
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET); a.sin_port = 0; a.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &a) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
            }
            guard ok, a.sin_port != 0 else { throw NSError(domain: "Tutun", code: 3, userInfo: [NSLocalizedDescriptionKey: tr("Нет свободного порта для проверки")]) }
            ports.append(Int(UInt16(bigEndian: a.sin_port)))
        }
        return ports
    }

    static func run(_ exe: String, _ args: [String], env: [String: String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    static func tcpOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
