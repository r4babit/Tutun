import notify
import Foundation
import CryptoKit
import TutunCore
import TutunSystem

/// Держит xray, sing-box (TUN) и вспомогательный sing-box запущенными, перезапускает при падении, проверяет связь.
final class Supervisor {
    struct Desired: Codable {
        var active = false
        var mode: ConnectionMode = .tun
        var killSwitch = true
        var serverLabel: String?
        var hasHelper = false
        var selector: SelectorParams?
        var current: String?        // через какой сервер (p0…pN) идём сейчас
        /// Уровень журнала «Отладка»: писать и ошибки каждого соединения ядер (с адресами сайтов).
        var verboseLog: Bool?
        /// Пока работает туннель, системный DNS мака смотрит в него (ConfigBuilder.capturesSystemDNS).
        var tunnelDNS: Bool?
        /// Адреса-заглушки для системного DNS (ConfigBuilder.systemDNSPlaceholders).
        var tunnelDNSServers: [String]?
        /// «Исключённые адреса»: идут мимо туннеля, блокировка их пропускает (FirewallRules).
        var excludedRoutes: [String]?
    }

    private let q = DispatchQueue(label: "tutund.supervisor")
    private var desired = Desired()
    private enum Phase {
        case stopped, starting, running(latency: Int), reconnecting(probeFailed: Bool), failed

        var state: TunnelState {
            switch self {
            case .stopped: return .stopped
            case .starting: return .starting
            case .running: return .running
            case .reconnecting: return .reconnecting
            case .failed: return .failed
            }
        }
    }

    private var phase: Phase = .stopped
    private var state: TunnelState { phase.state }

    private func transition(to next: Phase) {
        let changed = phase.state != next.state
        phase = next
        if guardsTraffic && firewall.isActive && next.state != .running && next.state != .stopped {
            do { try connectivityDNS.start() }
            catch { Log.write("Не включить локальную проверку сети macOS: \(error.localizedDescription)") }
        } else {
            connectivityDNS.stop()
        }
        if changed { notify_post(DaemonStatus.statusChangedNotification) }
        // Ответ на пробу из прошлого состояния уже не описывает текущее подключение.
        healthProbe = nil
    }
    private var since: Date?
    private var xray: Process?
    private var singBox: Process?
    private var helper: Process?
    private var restarts = 0
    private var xrayFailStreak = 0
    private var healthFailStreak = 0
    private var proxySet = false
    private let systemProxy = SystemProxyManager()
    private let connectivityDNS = ConnectivityCheckDNS()
    private let systemDNS = SystemDNSManager()
    private let firewall = TunnelFirewall(run: { runSync($0, $1, env: [:]) }, log: { Log.write($0) })
    private var generation = 0
    private var healthTimer: DispatchSourceTimer?
    private var healthProbe: UUID?
    private var selectionProbe: UUID?
    private var powerObserver: SystemWakeObserver?
    private var networkObserver: PhysicalNetworkObserver?
    private lazy var recovery = ConnectionRecovery(schedule: { [weak self] delay, action in
        let work = DispatchWorkItem(block: action)
        self?.q.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }, reconnect: { [weak self] reason in self?.restartTransport(reason) })
    private var statsCache: (Date, Int64, Int64, String?) = (.distantPast, 0, 0, nil)
    /// Полное пересоздание ядер из-за неудачных проверок — с растущей паузой (см. RestartBackoff).
    private var healthRestarts = RestartBackoff()
    private var restartDeferredLogged = false
    private static let noLinkReason = "Связи нет"

    private var xrayConfigPath: String { Paths.runDir + "/xray.json" }
    private var singBoxConfigPath: String { Paths.runDir + "/sing-box.json" }
    private var helperConfigPath: String { Paths.runDir + "/helper.json" }
    private let fm = FileManager.default

    // MARK: lifecycle

    func boot() {
        q.sync {
            try? fm.createDirectory(atPath: Paths.runDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            if let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.daemonState)),
               let saved = try? JSONDecoder.tunnel.decode(Desired.self, from: d) {
                desired = saved
            }
            protectAfterTunFailure()
            let protectionFailed = guardsTraffic && !firewall.isActive
            killStrays()
            do { try systemProxy.restore() }
            catch { Log.write(error.localizedDescription) }
            // Прошлый запуск мог не вернуть DNS (падение, выключение питания): возвращаем до любых подключений.
            do { try systemDNS.restore() }
            catch { Log.write(error.localizedDescription) }
            if protectionFailed {
                transition(to: .failed)
                startHealthTimer()
                return
            }
            if desired.active, let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.runDir + "/connection-plan.json")),
               let plan = try? JSONDecoder.tunnel.decode(ConfigBuilder.Input.self, from: data) {
                do {
                    try ConnectionValidation.validate(plan)
                    let config = ConfigBuilder.build(plan)
                    try write(config.xray, to: xrayConfigPath)
                    if let tun = config.singBox { try write(tun, to: singBoxConfigPath) }
                    if let helper = config.helper { try write(helper, to: helperConfigPath) }
                } catch {
                    transition(to: .failed)
                    Log.write("Не восстановить проверенный конфиг: \(error.localizedDescription)")
                    startHealthTimer(); return
                }
                Log.write("Служба запущена, восстанавливаю подключение")
                launch()
            } else if guardsTraffic {
                transition(to: .failed)
                Log.write("Нет сохранённого плана. Защита остаётся до отключения пользователем.")
            } else {
                desired.active = false; saveDesired()
                try? firewall.release()
                Log.write("Служба запущена. Для миграции со старой версии подключитесь через приложение заново.")
            }
            startHealthTimer()
        }
    }

    /// Called on the main queue once boot has restored the desired connection.
    func observeEnvironment() {
        powerObserver = SystemWakeObserver(onSleep: { [weak self] in
            self?.q.async {
                guard let self else { return }
                self.recovery.willSleep(); self.healthProbe = nil; self.selectionProbe = nil
                if self.desired.active {
                    self.transition(to: .reconnecting(probeFailed: false))
                    Log.write("Mac уходит в сон; подключение будет восстановлено после пробуждения")
                }
            }
        }, onWake: { [weak self] in
            self?.q.async { self?.recovery.didWake() }
        })
        if powerObserver?.start() != true { Log.write("Не удалось подписаться на пробуждение Mac") }
        networkObserver = PhysicalNetworkObserver(queue: q) { [weak self] fingerprint in
            self?.recovery.networkChanged(fingerprint)
        }
        q.sync { recovery.setActive(desired.active) }
    }

    func shutdown() {
        powerObserver?.stop(); powerObserver = nil; networkObserver = nil
        q.sync { recovery.setActive(false); protectAfterTunFailure(); stopProcesses(); Log.write("Служба остановлена") }
    }

    // MARK: commands

    func handle(_ req: DaemonRequest) -> DaemonStatus {
        switch req.cmd {
        case .ping, .status: return q.sync { status() }
        case .stop:
            return q.sync {
                desired.active = false; saveDesired(); recovery.setActive(false)
                stopProcesses(); transition(to: .stopped); since = nil
                do { try firewall.release() }
                catch { return fail(error.localizedDescription) }
                Log.write("Отключено пользователем")
                return status()
            }
        case .start:
            return q.sync { start(req) }
        case .updateGeo:
            return updateGeo(req)
        }
    }

    private func start(_ request: DaemonRequest) -> DaemonStatus {
        guard let plan = request.connection else { return fail("Обновите приложение: требуется описание подключения") }
        do { try ConnectionValidation.validate(plan) }
        catch { return fail(error.localizedDescription) }
        let built = ConfigBuilder.build(plan)
        if plan.settings.killSwitch && plan.settings.mode == .tun {
            do { try firewall.prepare() }
            catch { return fail(error.localizedDescription) }
        }
        var req = request
        req.mode = plan.settings.mode
        req.killSwitch = plan.settings.killSwitch
        req.xrayConfig = built.xray; req.singBoxConfig = built.singBox; req.helperConfig = built.helper
        req.selector = SelectorParams(candidates: plan.servers.count, intervalSec: plan.settings.probeIntervalSec,
                                      failLimit: plan.settings.healthFailLimit, testURL: plan.settings.testURL, timeoutSec: plan.settings.testTimeout)
        guard let xrayCfg = req.xrayConfig, let mode = req.mode else { return fail("Нет конфига") }
        if mode == .tun && req.singBoxConfig == nil { return fail("Нет конфига TUN") }

        // Проверяем конфиги до того, как трогать текущее подключение.
        let tmpX = Paths.runDir + "/xray.new.json", tmpS = Paths.runDir + "/sing-box.new.json", tmpH = Paths.runDir + "/helper.new.json"
        let tmpPlan = Paths.runDir + "/connection-plan.new.json"
        do {
            let data = try JSONEncoder.tunnel.encode(plan)
            try data.write(to: URL(fileURLWithPath: tmpPlan), options: .atomic)
            chmod(tmpPlan, 0o600)
            try write(xrayCfg, to: tmpX)
            let (c, out) = unprivileged(Paths.xray, ["run", "-test", "-c", "stdin:"], env: ["XRAY_LOCATION_ASSET": Paths.binDir], config: xrayCfg)
            guard c == 0 else { return fail("xray не принял конфиг: " + lastLines(out, 3)) }
            if let sb = req.singBoxConfig {
                try write(sb, to: tmpS)
                let (c2, out2) = runSync(Paths.singBox, ["check", "-c", tmpS], env: [:])
                guard c2 == 0 else { return fail("sing-box не принял конфиг: " + lastLines(out2, 3)) }
            }
            if let h = req.helperConfig {
                try write(h, to: tmpH)
                let (c3, out3) = unprivileged(Paths.singBox, ["check", "-c", "stdin"], env: [:], config: h)
                guard c3 == 0 else { return fail("sing-box (TUIC/Hysteria2) не принял конфиг: " + lastLines(out3, 3)) }
            }
        } catch { return fail("Не записать конфиг: \(error.localizedDescription)") }

        // Правила ставятся до остановки прежних ядер и остаются до «Отключить»: наружу — только ядра Tutun.
        if plan.settings.killSwitch && plan.settings.mode == .tun {
            do { try firewall.apply(FirewallPolicy(dns: .systemResolver, excludedRoutes: plan.settings.excludedRoutes)) }
            catch {
                let cause = error.localizedDescription
                if !guardsTraffic {
                    do { try firewall.release() }
                    catch { return fail(cause + ". " + error.localizedDescription) }
                }
                return fail(cause)
            }
        } else {
            do { try firewall.release() }
            catch { return fail(error.localizedDescription) }
        }
        stopProcesses()
        replace(tmpX, xrayConfigPath)
        replace(tmpPlan, Paths.runDir + "/connection-plan.json")
        if req.singBoxConfig != nil { replace(tmpS, singBoxConfigPath) }
        if req.helperConfig != nil { replace(tmpH, helperConfigPath) } else { try? fm.removeItem(atPath: helperConfigPath) }

        desired = Desired(active: true, mode: mode, killSwitch: req.killSwitch ?? true, serverLabel: req.serverLabel,
                          hasHelper: req.helperConfig != nil, selector: req.selector,
                          current: (req.selector?.candidates ?? 1) > 1 ? "p0" : nil,
                          verboseLog: plan.settings.logLevel == "debug",
                          tunnelDNS: ConfigBuilder.capturesSystemDNS(plan.settings),
                          tunnelDNSServers: ConfigBuilder.systemDNSPlaceholders(plan),
                          excludedRoutes: plan.settings.excludedRoutes)
        saveDesired()
        recovery.setActive(true)
        resetHealthRestarts()
        startHealthTimer()
        restarts = 0; since = nil
        Log.write("Подключение: \(req.serverLabel ?? "?"), режим \(mode == .tun ? "весь трафик" : "прокси")")
        launch()
        return status()
    }

    private func replace(_ from: String, _ to: String) {
        try? fm.removeItem(atPath: to); try? fm.moveItem(atPath: from, toPath: to)
    }

    private var geoProgress: GeoUpdateProgress?
    private let geoHeaders = Paths.runDir + "/geo-headers"

    private func setGeoStage(_ stage: GeoUpdateProgress.Stage, file: String? = nil) {
        q.sync {
            geoProgress = GeoUpdateProgress(stage: stage, file: file)
            notify_post(DaemonStatus.statusChangedNotification)
        }
    }

    private func currentGeoProgress() -> GeoUpdateProgress? {
        guard var progress = geoProgress, progress.stage == .downloading,
              let file = progress.file else { return geoProgress }
        let attrs = try? fm.attributesOfItem(atPath: Paths.runDir + "/" + file + ".new")
        progress.bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if let handle = FileHandle(forReadingAtPath: geoHeaders) {
            defer { try? handle.close() }
            let headers = String(decoding: handle.readData(ofLength: 64 * 1024), as: UTF8.self)
            // curl appends one header block per redirect. Only the final successful response counts.
            let lines = headers.components(separatedBy: "\r\n")
            if let i = lines.lastIndex(where: { $0.hasPrefix("HTTP/") }),
               let code = lines[i].split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
               (200..<300).contains(code) {
                for line in lines.dropFirst(i + 1).prefix(while: { !$0.isEmpty }) {
                    let fields = line.split(separator: ":", maxSplits: 1)
                    if fields.count == 2, fields[0].lowercased() == "content-length",
                       let length = Int64(fields[1].trimmingCharacters(in: .whitespaces)), length > 0 {
                        progress.total = length
                    }
                }
            }
        }
        return progress
    }

    // MARK: geo

    /// Скачивает geoip.dat / geosite.dat (через VPN, если он поднят), сверяет с опубликованной контрольной суммой,
    /// подменяет обе базы разом и проверяет, что текущий конфиг xray с ними загружается; иначе возвращает прежние.
    private func updateGeo(_ req: DaemonRequest) -> DaemonStatus {
        let acquired = q.sync {
            guard geoProgress == nil else { return false }
            geoProgress = GeoUpdateProgress(stage: .checking)
            return true
        }
        guard acquired else { return q.sync { fail("Обновление гео-баз уже выполняется") } }
        defer {
            try? fm.removeItem(atPath: geoHeaders)
            q.sync { geoProgress = nil; notify_post(DaemonStatus.statusChangedNotification) }
        }
        let viaProxy = q.sync { xray != nil && state == .running }
        func download(_ url: String, to path: String, seconds: Int) -> (Int32, String) {
            var args = ["-fsSL", "-m", "\(seconds)", "-o", path]
            if path.hasSuffix(".new") { args += ["--dump-header", geoHeaders] }
            args += ["--", url]
            if viaProxy { args = ["-x", "socks5h://127.0.0.1:\(Paths.socksPort)"] + args }
            return runSync("/usr/bin/curl", args, env: [:])
        }
        var fresh: [(name: String, tmp: String)] = []
        defer { for f in fresh { try? fm.removeItem(atPath: f.tmp) } }   // после подмены файла уже нет — no-op
        for (name, url) in [("geoip.dat", req.geoipURL), ("geosite.dat", req.geositeURL)] {
            guard let url, !url.isEmpty, url.hasPrefix("https://") else { continue }
            let tmp = Paths.runDir + "/\(name).new"
            try? fm.removeItem(atPath: tmp)
            try? fm.removeItem(atPath: geoHeaders)
            setGeoStage(.downloading, file: name)
            let (c, out) = download(url, to: tmp, seconds: 180)
            let size = (try? fm.attributesOfItem(atPath: tmp)[.size] as? Int) ?? 0
            guard c == 0, size > 100_000 else {
                try? fm.removeItem(atPath: tmp)
                return q.sync { fail("Не скачать \(name): \(c == 0 ? "файл слишком маленький" : lastLines(out, 1))") }
            }
            fresh.append((name, tmp))
            setGeoStage(.checking, file: name)
            // runetfreedom и Loyalsoldier кладут рядом <файл>.sha256sum. Нет его (свой адрес провайдера) —
            // остаётся проверка загрузкой в xray ниже.
            let sumPath = tmp + ".sha256sum"
            defer { try? fm.removeItem(atPath: sumPath) }
            if download(url + ".sha256sum", to: sumPath, seconds: 30).0 == 0,
               let text = try? String(contentsOfFile: sumPath, encoding: .utf8),
               let expected = text.split(whereSeparator: { $0.isWhitespace }).first.map({ $0.lowercased() }), expected.count == 64 {
                guard let data = fm.contents(atPath: tmp),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
                    return q.sync { fail("Контрольная сумма \(name) не совпала с опубликованной — база не заменена") }
                }
            } else {
                Log.write("Для \(name) нет опубликованной контрольной суммы — проверяю только загрузкой в xray")
            }
        }
        guard !fresh.isEmpty else { return q.sync { fail("Укажите HTTPS-адрес гео-базы") } }
        setGeoStage(.installing)
        var replaced: [String] = []
        func rollback() {
            for name in replaced.reversed() {
                let dst = Paths.binDir + "/" + name
                if fm.fileExists(atPath: dst + ".bak") { _ = rename(dst + ".bak", dst) }
                else { try? fm.removeItem(atPath: dst) }
            }
        }
        do {
            for f in fresh {
                let dst = Paths.binDir + "/" + f.name, bak = dst + ".bak"
                if fm.fileExists(atPath: bak) { try fm.removeItem(atPath: bak) }
                if fm.fileExists(atPath: dst) { try fm.copyItem(atPath: dst, toPath: bak) }
                guard chmod(f.tmp, 0o644) == 0, rename(f.tmp, dst) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                replaced.append(f.name)
            }
        } catch {
            rollback()
            return q.sync { fail(error.localizedDescription) }
        }
        // Текущий конфиг xray должен по-прежнему загружаться с новыми базами.
        if !replaced.isEmpty, fm.fileExists(atPath: xrayConfigPath) {
            let current = (try? String(contentsOfFile: xrayConfigPath, encoding: .utf8)) ?? ""
            let (c, out) = unprivileged(Paths.xray, ["run", "-test", "-c", "stdin:"], env: ["XRAY_LOCATION_ASSET": Paths.binDir], config: current)
            if c != 0 {
                rollback()
                return q.sync { fail("Новые гео-базы не подошли, вернул старые: " + lastLines(out, 2)) }
            }
        }
        return q.sync {
            Log.write("Гео-базы обновлены: \(replaced.joined(separator: ", "))")
            // Работающее ядро сохраняет соединения и прочитает новые базы при следующем запуске.
            var s = status(); s.info = "Обновлено: \(replaced.joined(separator: ", "))"; return s
        }
    }

    // MARK: processes

    private func launch() {
        generation += 1
        transition(to: .starting)
        healthFailStreak = 0
        if desired.hasHelper, helper == nil, fm.fileExists(atPath: helperConfigPath) { _ = startHelper() }
        guard startXray() else { scheduleXrayRestart(); return }
        guard waitPort(Paths.socksPort, timeout: 8) else {
            Log.write("xray не открыл порт за 8 с")
            if let p = xray { xray = nil; p.terminate() }
            scheduleXrayRestart(); return
        }
        bringUpFront()
    }

    /// Включает перехват трафика (TUN или системный прокси) поверх работающего xray.
    private func bringUpFront() {
        switch desired.mode {
        case .tun:
            if singBox == nil, !startSingBox() {
                protectAfterTunFailure(); transition(to: .reconnecting(probeFailed: false)); scheduleSingBoxRestart(); return
            }
            guard waitTun(timeout: 5) else {
                protectAfterTunFailure()
                if !desired.killSwitch { setSystemDNS(false) }
                if let p = singBox { p.terminate() }
                transition(to: .reconnecting(probeFailed: false))
                return
            }
            if proxySet { setSystemProxy(false) }
            setSystemDNS(desired.tunnelDNS == true)
        case .proxy:
            setSystemDNS(false)
            if let p = singBox { singBox = nil; p.terminate(); p.waitUntilExit() }
            if !proxySet { setSystemProxy(true) }
            guard proxySet else { transition(to: .failed); return }
        }
        applyCurrent()
        // Туннель поднят: блокировка остаётся (меняется только правило DNS), а не снимается, как до службы 2.15.
        do {
            if guardsTraffic { try firewall.apply(firewallPolicy(tunnelUp: true)) } else { try firewall.release() }
        } catch { Log.write(error.localizedDescription); transition(to: .failed); return }
        // The UI must wait for a successful server request, not merely an open SOCKS port.
        transition(to: since == nil ? .starting : .reconnecting(probeFailed: false))
        if since == nil { since = Date() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.q.async { self?.checkHealth() } }
    }

    private func startXray() -> Bool {
        let gen = generation
        guard let config = fm.contents(atPath: xrayConfigPath) else { Log.write("Нет конфига xray"); return false }
        guard let p = spawn(Paths.dropper, [Paths.xray, "run", "-c", "stdin:"], env: ["XRAY_LOCATION_ASSET": Paths.binDir],
                            tag: "xray", input: config) else { return false }
        xray = p
        p.terminationHandler = { [weak self] proc in self?.q.async { self?.xrayExited(proc, gen: gen) } }
        return true
    }

    private func startSingBox() -> Bool {
        let gen = generation
        // Через tutun-drop --root: права root остаются (нужны для utun), группа — _tutun, по ней PF пропускает «напрямую».
        guard let p = spawn(Paths.dropper, ["--root", Paths.singBox, "run", "--disable-color", "-c", singBoxConfigPath, "-D", Paths.runDir], env: [:], tag: "sing-box") else { return false }
        singBox = p
        p.terminationHandler = { [weak self] proc in self?.q.async { self?.singBoxExited(proc, gen: gen) } }
        return true
    }

    private func startHelper() -> Bool {
        let gen = generation
        guard let config = fm.contents(atPath: helperConfigPath) else { Log.write("Нет конфига TUIC/Hysteria2"); return false }
        guard let p = spawn(Paths.dropper, [Paths.singBox, "run", "--disable-color", "-c", "stdin"], env: [:],
                            tag: "tuic/hy2", input: config) else { return false }
        helper = p
        p.terminationHandler = { [weak self] proc in
            self?.q.async {
                guard let self, gen == self.generation, self.helper === proc, self.desired.active else { return }
                self.helper = nil; self.restarts += 1
                Log.write("Вспомогательное ядро завершилось (код \(proc.terminationStatus)), перезапуск через 2 с")
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.q.async { if let self, gen == self.generation, self.helper == nil, self.desired.active, !self.recovery.isSleeping, !self.recovery.isPending { _ = self.startHelper() } }
                }
            }
        }
        return true
    }

    private func xrayExited(_ p: Process, gen: Int) {
        guard gen == generation, xray === p, desired.active else { return }
        xray = nil
        restarts += 1
        Log.write("xray завершился (код \(p.terminationStatus)), перезапуск")
        scheduleXrayRestart()
    }

    private func singBoxExited(_ p: Process, gen: Int) {
        guard gen == generation, singBox === p, desired.active, desired.mode == .tun else { return }
        singBox = nil
        protectAfterTunFailure()
        // Без аварийной блокировки трафик идёт напрямую — значит, и DNS должен работать без туннеля.
        if !desired.killSwitch { setSystemDNS(false) }
        restarts += 1
        Log.write("sing-box завершился (код \(p.terminationStatus)), перезапуск через 2 с")
        transition(to: .reconnecting(probeFailed: false))
        scheduleSingBoxRestart()
    }

    private func scheduleSingBoxRestart() {
        let gen = generation
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.q.async {
                guard let self, gen == self.generation, self.desired.active, self.singBox == nil, self.xray != nil, !self.recovery.isSleeping, !self.recovery.isPending else { return }
                self.bringUpFront()
            }
        }
    }

    private func scheduleXrayRestart() {
        xrayFailStreak += 1
        transition(to: .reconnecting(probeFailed: false))
        // Без «блокировки при обрыве» отпускаем трафик напрямую, пока ядро не поднимется.
        if !desired.killSwitch {
            if let p = singBox { singBox = nil; p.terminate() }
            if proxySet { setSystemProxy(false) }
            setSystemDNS(false)
        }
        let delay = min(pow(2.0, Double(min(xrayFailStreak, 5))), 30)
        let gen = generation
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.q.async {
                guard let self, gen == self.generation, self.desired.active, self.xray == nil, !self.recovery.isSleeping, !self.recovery.isPending else { return }
                guard self.startXray(), self.waitPort(Paths.socksPort, timeout: 8) else {
                    if let p = self.xray { self.xray = nil; p.terminate() }
                    self.scheduleXrayRestart(); return
                }
                self.bringUpFront()
            }
        }
    }

    private func stopProcesses() {
        generation += 1
        healthProbe = nil; selectionProbe = nil; statsCache = (.distantPast, 0, 0, nil)
        for p in [singBox, xray, helper].compactMap({ $0 }) where p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        singBox = nil; xray = nil; helper = nil
        setSystemProxy(false)
        setSystemDNS(false)
    }

    private func killStrays() {
        _ = runSync("/usr/bin/pkill", ["-f", Paths.binDir + "/"], env: [:])
    }

    /// Блокировка трафика вне VPN действует: режим «весь трафик» и настройка включена.
    private var guardsTraffic: Bool { desired.active && desired.mode == .tun && desired.killSwitch }

    /// Пока туннель работает и системный DNS смотрит в него, порт 53 мимо туннеля закрыт. Без туннеля имена
    /// (адреса VPN-серверов) узнаёт системный резолвер — иначе не переподключиться.
    private func firewallPolicy(tunnelUp: Bool) -> FirewallPolicy {
        FirewallPolicy(dns: tunnelUp && systemDNS.isActive ? .tunnelOnly : .systemResolver,
                       excludedRoutes: desired.excludedRoutes ?? [])
    }

    /// Туннеля нет (старт службы, падение sing-box, остановка службы): правила на месте, DNS — системному резолверу.
    private func protectAfterTunFailure() {
        guard guardsTraffic else { return }
        do { try firewall.apply(firewallPolicy(tunnelUp: false)) }
        catch { Log.write("Ошибка блокировки трафика вне VPN: \(error.localizedDescription)"); transition(to: .failed) }
    }

    private func waitTun(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard singBox?.isRunning == true else { return false }
            if if_nametoindex("utun233") != 0 { return true }
            usleep(100_000)
        }
        return false
    }

    /// Recreate TUN and helper as well as xray: SOCKS can work while the old TUN is stuck.
    private func restartTransport(_ reason: String) {
        guard desired.active, !recovery.isSleeping else { return }
        if !reason.hasPrefix(Self.noLinkReason) { resetHealthRestarts() }
        if guardsTraffic {
            do { try firewall.apply(firewallPolicy(tunnelUp: false)) }
            catch { transition(to: .failed); Log.write(error.localizedDescription); return }
        }
        Log.write("\(reason) — восстанавливаю ядра и перехват трафика")
        transition(to: .reconnecting(probeFailed: false))
        stopProcesses()
        restarts += 1
        launch()
    }

    // MARK: health

    private var healthInterval: Int { max(10, desired.selector?.intervalSec ?? 30) }
    private var failLimit: Int { max(1, desired.selector?.failLimit ?? 3) }
    private var balanced: Bool { (desired.selector?.candidates ?? 1) > 1 }

    private func startHealthTimer() {
        healthTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        let i = healthInterval
        t.schedule(deadline: .now() + .seconds(i), repeating: .seconds(i))
        t.setEventHandler { [weak self] in self?.checkHealth() }
        t.resume()
        healthTimer = t
    }

    /// Запрос через xray (через текущий сервер) к generate_204. failLimit неудач подряд:
    /// есть другие серверы — переходим на самый быстрый из отвечающих; нет или никто не отвечает —
    /// восстанавливаем все ядра и TUN. Пока текущий отвечает, сервер не меняется.
    private func checkHealth() {
        guard recovery.canCheckHealth, desired.active, xray != nil,
              state == .running || state == .reconnecting || state == .starting else { return }
        if desired.mode == .tun && (singBox?.isRunning != true || if_nametoindex("utun233") == 0) {
            recovery.request("Потерян интерфейс TUN")
            return
        }
        guard healthProbe == nil, selectionProbe == nil else { return }
        let probe = UUID(), epoch = recovery.epoch
        healthProbe = probe
        let gen = generation
        let testURL = desired.selector?.testURL ?? "https://www.gstatic.com/generate_204"
        let timeout = max(2, min(30, desired.selector?.timeoutSec ?? 10))
        DispatchQueue.global().async { [weak self] in
            let start = Date()
            let (code, out) = runSync("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "\(timeout)",
                                                         "-x", "socks5h://127.0.0.1:\(Paths.healthPort)",
                                                         testURL], env: [:])
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            self?.q.async {
                guard let self, gen == self.generation, self.healthProbe == probe else { return }
                self.healthProbe = nil
                guard epoch == self.recovery.epoch, self.recovery.canCheckHealth else { return }
                let ok = code == 0 && Int(out.trimmingCharacters(in: .whitespacesAndNewlines)).map { (200..<400).contains($0) } == true
                if ok {
                    self.transition(to: .running(latency: ms))
                    self.healthFailStreak = 0; self.xrayFailStreak = 0
                    self.resetHealthRestarts()
                } else {
                    self.healthFailStreak += 1
                    Log.write("Проверка связи не прошла (\(self.healthFailStreak))")
                    // Одиночная неудача (сервер задумался дольше 5 с) — не обрыв: состояние и значок не трогаем,
                    // иначе приложение присылало «переподключается/восстановлена» каждую минуту (12.11.2026).
                    // Обрыв — только когда не прошли проверки подряд в количестве «Сервер не отвечает после».
                    if self.healthFailStreak >= self.failLimit || self.state != .running {
                        self.transition(to: .reconnecting(probeFailed: true))
                    }
                    if self.healthFailStreak >= self.failLimit {
                        self.healthFailStreak = 0
                        if self.balanced { self.switchToAlive() } else { self.restartXray() }
                    }
                }
            }
        }
    }

    private func restartXray() {
        guard healthRestarts.attempt() else {
            if !restartDeferredLogged {
                restartDeferredLogged = true
                let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
                Log.write("Связи по-прежнему нет; ядра пересоздам не раньше \(f.string(from: healthRestarts.nextAllowed)), проверки продолжаются")
            }
            return
        }
        restartDeferredLogged = false
        recovery.request("\(Self.noLinkReason) \(failLimit) проверки подряд")
    }

    private func resetHealthRestarts() {
        healthRestarts.reset(); restartDeferredLogged = false
    }

    // MARK: выбор сервера

    /// Говорит xray, через какой сервер идти (переопределение балансировщика «auto»).
    private func applyCurrent() {
        guard balanced, let tag = desired.current else { return }
        let (c, out) = runSync(Paths.xray, ["api", "bo", "--server=127.0.0.1:\(Paths.apiPort)", "-b", "auto", tag], env: [:])
        if c != 0 { Log.write("Не выбрать сервер \(tag): " + lastLines(out, 1)) }
    }

    /// Текущий сервер не отвечает: замеряем остальных через пробные входы и берём самого быстрого из ответивших.
    private func switchToAlive() {
        guard let sel = desired.selector, xray != nil else { return }
        let cur = desired.current ?? "p0", gen = generation
        let probe = UUID(), epoch = recovery.epoch
        selectionProbe = probe
        Log.write("Сервер \(cur) не отвечает \(failLimit) проверки подряд — ищу рабочий")
        DispatchQueue.global().async { [weak self] in
            let lock = NSLock(); var res: [(String, Int)] = []
            DispatchQueue.concurrentPerform(iterations: sel.candidates) { i in
                let tag = "p\(i)"
                guard tag != cur else { return }
                let (c, out) = runSync("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code} %{time_total}",
                                                         "-m", "\(max(2, sel.timeoutSec))",
                                                         "-x", "socks5h://127.0.0.1:\(Paths.probeBasePort + i)", sel.testURL], env: [:])
                let parts = out.split(separator: " ")
                guard c == 0, parts.count == 2, let code = Int(parts[0]), (200..<400).contains(code),
                      let t = Double(parts[1]) else { return }
                lock.lock(); res.append((tag, Int(t * 1000))); lock.unlock()
            }
            self?.q.async {
                guard let self, gen == self.generation, self.selectionProbe == probe else { return }
                self.selectionProbe = nil
                guard self.desired.active, epoch == self.recovery.epoch, self.recovery.canCheckHealth else { return }
                guard let best = res.min(by: { $0.1 < $1.1 }) else {
                    Log.write("Ни один сервер из списка не ответил")
                    self.restartXray(); return
                }
                self.desired.current = best.0; self.saveDesired()
                notify_post(DaemonStatus.statusChangedNotification)
                self.applyCurrent()
                self.statsCache.0 = .distantPast
                Log.write("Переключился на \(best.0) (\(best.1) мс)")
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.q.async { self?.checkHealth() } }
            }
        }
    }

    // MARK: system proxy

    private func setSystemProxy(_ on: Bool) {
        do {
            if on { try systemProxy.enable() } else { try systemProxy.restore() }
            proxySet = on
            Log.write(on ? "Системный прокси включён" : "Прежний системный прокси восстановлен")
        } catch {
            Log.write(error.localizedDescription)
            transition(to: .failed)
        }
    }

    // MARK: system DNS

    private func setSystemDNS(_ on: Bool) {
        guard on != systemDNS.isActive else { return }
        do {
            if on { try systemDNS.enable(servers: desired.tunnelDNSServers ?? SystemDNSManager.defaultServers) } else { try systemDNS.restore() }
            Log.write(on ? "DNS мака идёт через туннель" : "Прежний DNS мака восстановлен")
        } catch {
            // Не роняем подключение: без подмены DNS просто идёт как раньше, мимо туннеля.
            Log.write(error.localizedDescription)
        }
    }

    // MARK: status

    private func status() -> DaemonStatus {
        var s = DaemonStatus()
        s.geoProgress = currentGeoProgress()
        s.state = state
        s.mode = desired.active ? desired.mode : nil
        s.serverLabel = desired.active ? desired.serverLabel : nil
        s.since = since
        s.restarts = restarts
        switch phase {
        case .running(let latency): s.healthy = true; s.latencyMs = latency
        case .reconnecting(true), .failed: s.healthy = false
        default: break
        }
        s.killSwitch = desired.killSwitch
        s.blocking = firewall.isActive && state != .running
        s.log = Log.tail(120)
        if xray != nil, state == .running || state == .reconnecting {
            let (up, down, active) = stats()
            s.uplink = up; s.downlink = down; s.activeOutbound = balanced ? desired.current : active
        }
        return s
    }

    private func stats() -> (Int64, Int64, String?) {
        if Date().timeIntervalSince(statsCache.0) < 0.8 { return (statsCache.1, statsCache.2, statsCache.3) }
        let api = "--server=127.0.0.1:\(Paths.apiPort)"
        var up: Int64 = 0, down: Int64 = 0
        let (c, out) = runSync(Paths.xray, ["api", "statsquery", api, "-pattern", "outbound>>>"], env: [:])
        if c == 0, let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
           let stats = obj["stat"] as? [[String: Any]] {
            for st in stats {
                guard let name = st["name"] as? String else { continue }
                let parts = name.components(separatedBy: ">>>")
                guard parts.count == 4, parts[1].hasPrefix("p") else { continue }
                let v = (st["value"] as? NSNumber)?.int64Value ?? Int64("\(st["value"] ?? 0)") ?? 0
                if parts[3] == "uplink" { up += v } else { down += v }
            }
        }
        var active: String?
        // Ответ: «- Selects: 1 p8» — берём первый выбранный после «Selects».
        let (c2, out2) = runSync(Paths.xray, ["api", "bi", api, "auto"], env: [:])
        if c2 == 0, let sel = out2.range(of: "Selects:"),
           let r = out2[sel.upperBound...].range(of: #"\bp\d+\b"#, options: .regularExpression) {
            active = String(out2[r])
        }
        statsCache = (Date(), up, down, active)
        return (up, down, active)
    }

    private func fail(_ msg: String) -> DaemonStatus {
        Log.write(msg)
        var s = status(); s.ok = false; s.error = msg
        return s
    }

    // MARK: helpers

    private func saveDesired() {
        if let d = try? JSONEncoder.tunnel.encode(desired) {
            try? d.write(to: URL(fileURLWithPath: Paths.daemonState), options: .atomic)
            chmod(Paths.daemonState, 0o600)
        }
    }

    private func write(_ s: String, to path: String) throws {
        try s.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o600)
    }

    private func waitPort(_ port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tcpOpen(port) { return true }
            if xray?.isRunning == false { return false }
            usleep(100_000)
        }
        return false
    }

    private func tcpOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    private func spawn(_ exe: String, _ args: [String], env: [String: String], tag: String, input: Data? = nil) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(env) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let verbose = desired.verboseLog == true
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n") where verbose || !CoreLogFilter.isConnectionNoise(line) {
                Log.write("[\(tag)] \(line)", echo: false)
            }
        }
        let stdin = input.map { _ in Pipe() }
        if let stdin { p.standardInput = stdin }
        do { try p.run() } catch { Log.write("Не запустить \(tag): \(error.localizedDescription)"); return nil }
        if let stdin, let input { feed(stdin, input) }
        return p
    }

    private func lastLines(_ s: String, _ n: Int) -> String {
        s.split(separator: "\n").filter { !$0.contains("[Warning]") && !$0.contains("[Info]") }.suffix(n).joined(separator: " | ")
    }
}

@discardableResult
/// Ядра, которые разбирают конфиги серверов от провайдера (xray, вспомогательный sing-box), работают
/// без прав: через tutun-drop от пользователя nobody, конфиг — через стандартный ввод (файлы с ключами — только root).
/// Так даже ошибка в проверке конфига не даст ядру прочитать или изменить файлы мака.
func unprivileged(_ exe: String, _ args: [String], env: [String: String], config: String) -> (Int32, String) {
    runSync(Paths.dropper, [exe] + args, env: env, input: Data(config.utf8))
}

/// Пишет конфиг в стандартный ввод ядра в фоне: большой конфиг не помещается в буфер канала целиком.
/// Ошибка записи (ядро вышло раньше) не роняет службу: SIGPIPE игнорируется, write(contentsOf:) бросает ошибку.
func feed(_ pipe: Pipe, _ data: Data) {
    DispatchQueue.global().async {
        let h = pipe.fileHandleForWriting
        try? h.write(contentsOf: data)
        try? h.close()
    }
}

func runSync(_ exe: String, _ args: [String], env: [String: String], input: Data? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(env) { $1 }
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    let stdin = input.map { _ in Pipe() }
    if let stdin { p.standardInput = stdin }
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    if let stdin, let input { feed(stdin, input) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Журнал: кольцевой буфер для окна приложения + файл /var/log/tutun.log.
/// Файл читают только root и администраторы мака (0640 root:admin). Больше 5 МБ — прежний уходит в tutun.log.1.
enum Log {
    private static let lock = NSLock()
    private static var ring: [String] = []
    private static let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm:ss"; return f }()
    private static let adminGroup: gid_t = getgrnam("admin")?.pointee.gr_gid ?? 80

    /// При старте службы: закрыть журнал и состояние от других пользователей (в прошлых версиях были 0644).
    static func secureFiles() {
        for path in [Paths.log, Paths.log + ".1"] where FileManager.default.fileExists(atPath: path) {
            chown(path, 0, adminGroup); chmod(path, 0o640)
        }
        if FileManager.default.fileExists(atPath: Paths.daemonState) { chmod(Paths.daemonState, 0o600) }
    }

    static func write(_ msg: String, echo: Bool = true) {
        let line = "\(df.string(from: Date())) \(msg)"
        lock.lock(); defer { lock.unlock() }
        ring.append(line); if ring.count > 400 { ring.removeFirst(ring.count - 400) }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: Paths.log), (attrs[.size] as? Int ?? 0) > 5 << 20 {
            _ = rename(Paths.log, Paths.log + ".1")
        }
        if !fm.fileExists(atPath: Paths.log) {
            fm.createFile(atPath: Paths.log, contents: nil, attributes: [.posixPermissions: 0o640])
            chown(Paths.log, 0, adminGroup)
        }
        if let h = FileHandle(forWritingAtPath: Paths.log) {
            h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
        }
    }

    static func tail(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring.suffix(n))
    }
}
