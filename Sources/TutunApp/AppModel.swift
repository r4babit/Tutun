import notify
import Foundation
import SwiftUI
import Network
import ServiceManagement
import CryptoKit
import IOKit
import TutunCore

struct DayStat: Codable, Hashable { var up: Int64 = 0; var down: Int64 = 0 }

enum SidePanel: String { case servers, settings, add }

/// Этап установки или обновления службы — показывается на месте кнопки, пока идёт.
enum DaemonInstallStage {
    case installing, updating, starting, done
    var title: String {
        switch self {
        case .installing: return tr("Устанавливаю службу…")
        case .updating: return tr("Обновляю службу…")
        case .starting: return tr("Запускаю службу…")
        case .done: return tr("Служба установлена")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct Store: Codable {
        var servers: [Server] = []
        var subscriptions: [Subscription] = []
        var profiles: [RoutingProfile] = []
        var settings = AppSettings()
        var days: [String: DayStat] = [:]
        var serverUsage: [String: Int64] = [:]
        var hidden: [String] = []
        var lastExpiryWarn: [String: Date] = [:]
        /// Серверы последнего подключения (p0, p1, …) — чтобы после перезапуска окна знать, через какой идёт VPN.
        var lastCandidateIDs: [String] = []
        /// Последние результаты проверки задержки — чтобы список не открывался с прочерками.
        var pings: [String: Int] = [:]

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
            subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
            profiles = try c.decodeIfPresent([RoutingProfile].self, forKey: .profiles) ?? []
            settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
            days = try c.decodeIfPresent([String: DayStat].self, forKey: .days) ?? [:]
            serverUsage = try c.decodeIfPresent([String: Int64].self, forKey: .serverUsage) ?? [:]
            hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
            lastExpiryWarn = try c.decodeIfPresent([String: Date].self, forKey: .lastExpiryWarn) ?? [:]
            lastCandidateIDs = try c.decodeIfPresent([String].self, forKey: .lastCandidateIDs) ?? []
            pings = try c.decodeIfPresent([String: Int].self, forKey: .pings) ?? [:]
        }
    }

    @Published var servers: [Server] = [] { didSet { scheduleSave() } }
    @Published var subscriptions: [Subscription] = [] { didSet { scheduleSave() } }
    @Published var profiles: [RoutingProfile] = [] { didSet { scheduleSave() } }
    @Published var settings = AppSettings() { didSet { settingsChanged(oldValue) } }
    /// Язык интерфейса. Не часть черновика настроек: меняется сразу, без «Принять изменения».
    @Published var language: AppLanguage = L10n.choice { didSet { L10n.set(language) } }
    @Published private(set) var appliedSettings = AppSettings()
    @Published var days: [String: DayStat] = [:]
    @Published var serverUsage: [String: Int64] = [:]
    @Published var hidden: Set<String> = [] { didSet { scheduleSave() } }
    private var lastExpiryWarn: [String: Date] = [:]

    @Published var status = DaemonStatus()
    @Published var daemonReachable = false
    @Published var pings: [String: Int] = [:] { didSet { scheduleSave() } }   // мс; -1 — недоступен
    @Published var speeds: [String: Double] = [:]   // байт/с
    @Published var testing = false
    @Published var speedTesting: String?
    @Published private(set) var geoUpdateRequested = false
    @Published private(set) var geoUpdateError: String?
    @Published var busy = false
    @Published var message: String?
    @Published var speedUp: Double = 0
    @Published var speedDown: Double = 0
    @Published var history: [Double] = Array(repeating: 0, count: 60)
    @Published var updatingSubs = false
    @Published var needsReconnect = false
    @Published var connections: [Conn] = []
    @Published var watchConnections = false
    @Published var ipVPN: IPInfo?
    @Published var ipDirect: IPInfo?
    @Published var conflicts: [String] = []
    /// Идёт установка/обновление службы (пароль, копирование, запуск). Пока не nil, кнопки службы не показываются.
    @Published private(set) var daemonInstallStage: DaemonInstallStage?

    /// Серверы, отданные службе при последнем подключении (p0, p1, … → сервер).
    private var lastCandidates: [Server] = [] { didSet { scheduleSave() } }
    private var lastSample: (Date, Int64, Int64)?
    private var lastActive: String?
    private var lastState: TunnelState = .stopped
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "Tutun.persistence")
    private var notificationToken: Int32 = -1
    private var eventRefreshScheduled = false
    private var pendingStatusEvent = false

    deinit {
        if notificationToken >= 0 { notify_cancel(notificationToken) }
    }

    private func scheduleEventRefresh() {
        guard !eventRefreshScheduled else { return }
        eventRefreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            eventRefreshScheduled = false
            if statusInFlight { pendingStatusEvent = true }
            else { await refreshStatus() }
        }
    }

    private var timers: [Timer] = []
    private var loaded = false

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Tutun", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        chmod(d.path, 0o700)
        // Перенос настроек со старого имени (Tunnel).
        let old = base.appendingPathComponent("Tunnel/app.json"), new = d.appendingPathComponent("app.json")
        if !FileManager.default.fileExists(atPath: new.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: new)
        }
        return d
    }()
    static var storeURL: URL { dir.appendingPathComponent("app.json") }

    var clashSecret: String {
        SHA256.hash(data: Data(("clash" + appliedSettings.hwid).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private init() {
        Tester.killLeftovers()
        load()
        if settings.hwid.isEmpty {
            // Новая установка: ID как ждут панели провайдеров (UUID), одинаковый после переустановки.
            // У существующих установок ID не меняется — иначе провайдер посчитал бы мак новым устройством.
            settings.hwid = Self.hardwareUUID().map(ProviderOptions.deviceID(fromHardwareUUID:))
                ?? (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            appliedSettings = settings
        }
        loaded = true
        if settings.notifications { Notifier.requestAuth() }

        var token: Int32 = -1
        if notify_register_dispatch(DaemonStatus.statusChangedNotification, &token, .main, { [weak self] _ in
            Task { @MainActor in self?.scheduleEventRefresh() }
        }) == 0 { notificationToken = token }

        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.statusTick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshConnections() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.periodic() }
        })
        Task {
            await refreshStatus()
            conflicts = detectConflicts()
            // Одна общая проверка после запуска, а не по одной после каждой подписки и ещё одна сверху
            // (было три полных проверки подряд — 6–8 минут, кнопки проверки всё это время неактивны).
            if appliedSettings.updateSubsOnLaunch { await updateDueSubscriptions(force: true, ping: false) }
            if appliedSettings.pingOnLaunch || (appliedSettings.updateSubsOnLaunch && appliedSettings.pingAfterUpdate) { await pingAll() }
            if appliedSettings.connectOnLaunch, !isConnected, daemonReachable { await connect() }
            await periodic()
            await Updater.shared.checkIfDue()
        }
    }

    // MARK: derived

    var isConnected: Bool { status.state == .running || status.state == .reconnecting || status.state == .starting }
    var daemonInstalled: Bool { FileManager.default.fileExists(atPath: Paths.daemonPlist) }
    var daemonOutdated: Bool { daemonReachable && status.version != DaemonStatus.daemonVersion }
    var oldDaemonInstalled: Bool { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/local.tunnel.daemon.plist") }

    func displayName(_ s: Server) -> String { settings.serverRenames[s.id] ?? s.name }

    var visibleServers: [Server] { servers.filter { !hidden.contains($0.id) } }

    func pingValue(_ s: Server) -> Int { pings[s.id].map { $0 < 0 ? Int.max : $0 } ?? Int.max - 1 }

    func sorted(_ list: [Server]) -> [Server] {
        list.sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            switch settings.sort {
            case .ping:
                let pa = pingValue(a), pb = pingValue(b)
                if pa != pb { return pa < pb }
                return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
            case .name: return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
            case .none: return false
            }
        }
    }

    var sortedServers: [Server] { sorted(visibleServers) }

    /// Серверы, которые можно отдавать ядру (не скрытые, из включённых подписок, допустимые).
    var usableServers: [Server] {
        let disabled = Set(subscriptions.filter { !$0.enabled }.map(\.id))
        return visibleServers.filter { LinkParser.rejectReason($0) == nil && !($0.subscriptionID.map(disabled.contains) ?? false) }
    }

    var selectedServer: Server? { servers.first { $0.id == settings.selectedServerID } }
    var activeProfile: RoutingProfile? { profiles.first { $0.id == settings.activeProfileID } }

    var activeServerName: String? { activeCandidate.map { displayName($0) } }

    private var activeCandidate: Server? {
        if let tag = status.activeOutbound, let i = Int(tag.dropFirst()), lastCandidates.indices.contains(i) {
            return lastCandidates[i]
        }
        if lastCandidates.count == 1 { return lastCandidates[0] }
        return nil
    }

    // MARK: persistence

    private func load() {
        guard let d = try? Data(contentsOf: Self.storeURL),
              let s = try? JSONDecoder.tunnel.decode(Store.self, from: d) else { return }
        servers = s.servers; subscriptions = s.subscriptions; profiles = s.profiles
        settings = s.settings; appliedSettings = s.settings
        days = s.days; serverUsage = s.serverUsage; hidden = Set(s.hidden); lastExpiryWarn = s.lastExpiryWarn
        lastCandidates = s.lastCandidateIDs.compactMap { id in s.servers.first { $0.id == id } }
        pings = s.pings
    }

    var store: Store {
        var s = Store()
        s.servers = servers; s.subscriptions = subscriptions; s.profiles = profiles; s.settings = appliedSettings
        s.days = days; s.serverUsage = serverUsage; s.hidden = Array(hidden); s.lastExpiryWarn = lastExpiryWarn
        s.lastCandidateIDs = lastCandidates.map(\.id)
        s.pings = pings
        return s
    }

    func scheduleSave() {
        guard loaded else { return }
        saveWork?.cancel()
        let snapshot = store
        let w = DispatchWorkItem {
            guard let d = try? JSONEncoder.tunnel.encode(snapshot) else { return }
            try? d.write(to: Self.storeURL, options: .atomic)
            chmod(Self.storeURL.path, 0o600)   // в файле ссылка подписки и ключи серверов
        }
        saveWork = w
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Изменения, которые требуют пересобрать подключение.
    private func settingsChanged(_ old: AppSettings) {
        guard loaded else { return }
        // Выбор сервера и состояние списка — действия главного экрана, а не черновик настроек.
        appliedSettings = SettingsPolicy.mergingRuntimeChanges(from: old, to: settings, accepted: appliedSettings)
        needsReconnect = settings != appliedSettings
        scheduleSave()
    }

    func applySettings() async {
        guard !busy else { return }
        let old = appliedSettings
        let candidate = settings
        if old.launchAtLogin != candidate.launchAtLogin {
            do {
                if candidate.launchAtLogin { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { message = tr("Автозапуск: \(error.localizedDescription)"); return }
        }
        appliedSettings = candidate
        needsReconnect = settings != appliedSettings
        if old.notifications != candidate.notifications, candidate.notifications { Notifier.requestAuth() }
        saveWork?.cancel()
        do {
            let snapshot = try JSONEncoder.tunnel.encode(store)
            try saveQueue.sync {
                try snapshot.write(to: Self.storeURL, options: .atomic)
                chmod(Self.storeURL.path, 0o600)
            }
        } catch {
            appliedSettings = old
            needsReconnect = settings != old
            message = tr("Не удалось сохранить настройки: \(error.localizedDescription)")
            return
        }
        if isConnected { await connect() }
    }

    // MARK: daemon

    private func call(_ req: DaemonRequest, timeout: TimeInterval = 30) async throws -> DaemonStatus {
        try await Task.detached { try IPC.send(req, timeout: timeout) }.value
    }

    private var statusInFlight = false
    private var statusFailures = 0
    private var lastStatusRefresh = Date.distantPast

    /// Открыто ли что-то из окон Tutun (главное окно, панель в строке меню, соединения/статистика/журнал).
    /// Сам значок в строке меню — окно NSStatusBarWindow, оно видно всегда и не считается.
    static var uiVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.className != "NSStatusBarWindow" }
    }

    /// Видимые графики обновляются каждую секунду. В фоне достаточно событий и редкой сверки.
    private func statusTick() async {
        let fallback: TimeInterval = notificationToken >= 0 && daemonReachable && !daemonOutdated ? 30 : 5
        guard Self.uiVisible || Date().timeIntervalSince(lastStatusRefresh) >= fallback else { return }
        await refreshStatus()
    }

    func refreshStatus() async {
        // Не копим параллельные запросы, если служба отвечает медленно.
        guard !statusInFlight else { return }
        statusInFlight = true
        defer {
            statusInFlight = false
            lastStatusRefresh = Date()
            if pendingStatusEvent {
                pendingStatusEvent = false
                scheduleEventRefresh()
            }
        }
        do {
            let s = try await call(DaemonRequest(cmd: .status), timeout: 8)
            daemonReachable = true
            statusFailures = 0
            account(s)
            status = s
        } catch {
            // Служба занята долгой командой (подключение, восстановление после сна) и ответила позже срока:
            // это не «отключено». Сокета нет — служба действительно не запущена, это видно сразу.
            statusFailures += 1
            let notRunning: Bool
            if case IPC.Failure.notRunning = error { notRunning = true } else { notRunning = false }
            guard notRunning || statusFailures >= 3 else { return }
            daemonReachable = false
            status = DaemonStatus()
        }
        stateChanged()
    }

    private func account(_ s: DaemonStatus) {
        let now = Date()
        var du: Int64 = 0, dd: Int64 = 0
        if let (t, u, d) = lastSample, s.uplink >= u, s.downlink >= d {
            du = s.uplink - u; dd = s.downlink - d
            let dt = max(now.timeIntervalSince(t), 0.1)
            speedUp = Double(du) / dt; speedDown = Double(dd) / dt
        } else { speedUp = 0; speedDown = 0 }
        lastSample = (now, s.uplink, s.downlink)
        history.append(speedUp + speedDown); if history.count > 60 { history.removeFirst(history.count - 60) }
        if du + dd > 0 {
            let key = Self.dayKey(now)
            var st = days[key] ?? DayStat(); st.up += du; st.down += dd; days[key] = st
            if let name = activeServerName { serverUsage[name, default: 0] += du + dd }
            if Int(now.timeIntervalSince1970) % 30 == 0 { scheduleSave() }
        }
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private var reconnectingSince: Date?
    private var reconnectNotified = false

    private func stateChanged() {
        let settings = appliedSettings
        let st = status.state
        defer { lastState = st; lastActive = status.activeOutbound }
        // IP и страна — при появлении связи (в том числе когда окно открыли при уже работающем VPN) и при смене сервера.
        if st == .running && (lastState != .running || (status.activeOutbound != nil && status.activeOutbound != lastActive)) {
            Task { await checkIP() }
        }
        if st == .stopped && lastState != .stopped { ipVPN = nil }
        // Пока служба переустанавливается, «отключён/подключён» — это сама установка, а не события VPN.
        let notify = settings.notifications && daemonInstallStage == nil
        guard notify, st != lastState else {
            if notify, st == .running, let a = status.activeOutbound, let prev = lastActive, a != prev, let name = activeServerName {
                Notifier.send(tr("Tutun: сервер сменился"), tr("Сейчас: \(name)"))
            }
            return
        }
        switch st {
        case .running where lastState == .starting || lastState == .stopped: Notifier.send(tr("Tutun подключён"), status.serverLabel ?? "")
        case .running:
            // «Восстановлена» — только если до этого сообщили о пропаже связи.
            if reconnectNotified { Notifier.send(tr("Tutun: связь восстановлена")) }
            reconnectNotified = false
        case .reconnecting:
            // Короткие провалы (пересоздание после сна, смена сервера) не стоят уведомления:
            // сообщаем, только если связи нет дольше 20 секунд.
            let since = Date(); reconnectingSince = since
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard self.reconnectingSince == since, self.status.state == .reconnecting, self.appliedSettings.notifications else { return }
                self.reconnectNotified = true
                Notifier.send(tr("Tutun переподключается"), tr("Связь с сервером пропала"))
            }
        case .stopped where lastState != .stopped: Notifier.send(tr("Tutun отключён"))
        case .failed: Notifier.send(tr("Tutun: ошибка подключения"), message ?? "")
        default: break
        }
    }

    func toggle() async { isConnected ? await disconnect() : await connect() }

    func connect() async {
        guard !busy else { return }
        // Новое подключение всегда использует принятые настройки, не затрагивая черновик.
        let settings = appliedSettings
        let selectedServer = servers.first { $0.id == settings.selectedServerID }
        let activeProfile = profiles.first { $0.id == settings.activeProfileID }
        let clashSecret = SHA256.hash(data: Data(("clash" + settings.hwid).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        guard daemonReachable else { message = tr("Служба не запущена — установите её в настройках"); return }
        if daemonOutdated { message = tr("Служба устарела — нажмите «Обновить службу» в настройках"); return }
        guard !servers.isEmpty else { message = tr("Нет серверов — добавьте подписку"); return }
        if !settings.autoSelect, let s = selectedServer, let why = LinkParser.rejectReason(s) {
            message = tr("«\(displayName(s))»: \(why). Выберите другой сервер."); return
        }
        var (candidates, failoverOnly) = pickCandidates(settings: settings)
        guard !candidates.isEmpty else { message = tr("Нет подходящих серверов"); return }
        let chain = settings.chainServerID.flatMap { id in servers.first { $0.id == id } }
            .flatMap { c in candidates.contains(where: { $0.id == c.id }) ? nil : c }
        busy = true; defer { busy = false }
        var dropped: [String] = []
        // Если ядро забракует какой-то сервер (ошибка «tag pN»), убираем его и пробуем снова.
        for _ in 0..<6 {
            let provider = Self.providerSubscription(of: candidates, in: subscriptions)
            let plan = ConfigBuilder.Input(servers: candidates, settings: Self.applyingProviderOptions(provider, to: settings), profile: activeProfile, chain: chain,
                                           failoverOnly: failoverOnly && candidates.count == 2, clashSecret: clashSecret,
                                           serverResolve: provider?.serverResolve)
            do { try ConnectionValidation.validate(plan) }
            catch { message = error.localizedDescription; return }
            var req = DaemonRequest(cmd: .start)
            req.mode = settings.mode
            req.killSwitch = settings.killSwitch
            req.connection = plan
            req.selector = SelectorParams(candidates: candidates.count, intervalSec: settings.probeIntervalSec,
                                          failLimit: settings.healthFailLimit, testURL: settings.testURL,
                                          timeoutSec: settings.testTimeout)
            req.serverLabel = (failoverOnly || candidates.count == 1) ? displayName(candidates[0])
                : (!settings.autoSelect ? settings.selectedCountry.map { Server.countryName($0) } : nil) ?? tr("Самый быстрый")
            do {
                let s = try await call(req)
                status = s
                if s.ok {
                    lastCandidates = candidates; needsReconnect = self.settings != appliedSettings; lastSample = nil
                    message = dropped.isEmpty ? nil : tr("Пропущены серверы, которые ядро не приняло: ") + dropped.joined(separator: ", ")
                    Task { try? await Task.sleep(nanoseconds: 4_000_000_000); await self.checkIP() }
                    return
                }
                let err = s.error ?? ""
                if candidates.count > 1, let i = badTag(in: err), candidates.indices.contains(i) {
                    dropped.append(displayName(candidates[i]))
                    candidates.remove(at: i)
                    if candidates.count < 2 { failoverOnly = false }
                    continue
                }
                message = Self.friendly(err, server: candidates.count == 1 ? displayName(candidates[0]) : nil)
                return
            } catch { message = error.localizedDescription; return }
        }
        message = tr("Не удалось подключиться: ядро не приняло несколько серверов подряд")
    }

    /// Подписка, к которой относятся все серверы подключения (настройки провайдера применяются только тогда).
    static func providerSubscription(of servers: [Server], in subscriptions: [Subscription]) -> Subscription? {
        let ids = Set(servers.compactMap(\.subscriptionID))
        guard ids.count == 1, servers.allSatisfy({ $0.subscriptionID != nil }), let id = ids.first else { return nil }
        return subscriptions.first { $0.id == id }
    }

    /// Фрагментация и шум от провайдера — только если пользователь не включил свои: его выбор важнее.
    static func applyingProviderOptions(_ sub: Subscription?, to settings: AppSettings) -> AppSettings {
        var s = settings
        if !s.fragment, let f = sub?.providerFragment {
            s.fragment = true; s.fragmentPackets = f.packets; s.fragmentLength = f.length; s.fragmentInterval = f.interval
        }
        if !s.noises, let n = sub?.providerNoises {
            s.noises = true; s.noisesType = n.type; s.noisesPacket = n.packet; s.noisesDelay = n.delay
        }
        return s
    }

    /// IOPlatformUUID мака — только для хеша ID устройства, в открытом виде никуда не уходит.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private func badTag(in err: String) -> Int? {
        guard let r = err.range(of: #"tag p(\d+)"#, options: .regularExpression) else { return nil }
        return Int(err[r].dropFirst(5))
    }

    /// Короткое сообщение вместо вывода ядра: без предупреждений [Warning], только суть.
    static func friendly(_ err: String, server: String?) -> String {
        let parts = err.components(separatedBy: " | ").filter { !$0.contains("[Warning]") }
        var core = parts.joined(separator: " ")
        if let last = core.components(separatedBy: "> ").last, core.contains("> ") { core = last }
        let prefix = err.hasPrefix("sing-box") ? tr("Не удалось включить перехват трафика") : tr("Не удалось подключиться")
        return prefix + (server.map { tr(" к «\($0)»") } ?? "") + ": " + core.trimmingCharacters(in: .whitespaces)
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { status = try await call(DaemonRequest(cmd: .stop)); message = nil; ipVPN = nil }
        catch { message = error.localizedDescription }
    }

    func reconnect() async { await applySettings() }

    private func pickCandidates(settings: AppSettings) -> ([Server], Bool) {
        let usable = usableServers
        let selectedServer = servers.first { $0.id == settings.selectedServerID }
        if !settings.autoSelect, let code = settings.selectedCountry {
            if let r = countryCandidates(code, usable: usable, settings: settings) { return r }
        }
        if !settings.autoSelect, let s = selectedServer {
            guard settings.failover, let backup = sorted(usable.filter { $0.id != s.id && (pings[$0.id] ?? 0) >= 0 }).first else { return ([s], false) }
            return ([s, backup], true)
        }
        // «Самый быстрый» выбирает из всех серверов; избранное — только для быстрого доступа в списке.
        let pool = usable
        // Самые быстрые, недоступные — в конец; не больше 25, чтобы проверка не грузила сеть.
        let byPing = pool.sorted { pingValue($0) < pingValue($1) }
        let alive = byPing.filter { (pings[$0.id] ?? 0) >= 0 }
        return (Array((alive.isEmpty ? byPing : alive).prefix(25)), false)
    }

    /// Серверы для клика по стране — по настройке «Клик по стране».
    private func countryCandidates(_ code: String, usable: [Server], settings: AppSettings) -> ([Server], Bool)? {
        var inCountry = usable.filter { $0.countryCode == code }
        if settings.countryPreferFavorites {
            let favs = inCountry.filter(\.favorite)
            if !favs.isEmpty { inCountry = favs }
        }
        guard !inCountry.isEmpty else { return nil }
        let alive = inCountry.filter { (pings[$0.id] ?? 0) >= 0 }
        let pool = alive.isEmpty ? inCountry : alive
        func single(_ s: Server) -> ([Server], Bool) {
            // Одиночный сервер + запасной самый быстрый в той же стране (если включена подстраховка).
            guard settings.failover, let backup = pool.filter({ $0.id != s.id }).min(by: { pingValue($0) < pingValue($1) }) else { return ([s], false) }
            return ([s, backup], true)
        }
        switch settings.countryPick {
        case .fastest:
            return (Array(pool.sorted { pingValue($0) < pingValue($1) }.prefix(10)), false)
        case .lastUsed:
            if let id = settings.lastServerByCountry[code], let s = inCountry.first(where: { $0.id == id }) { return single(s) }
            return (Array(pool.sorted { pingValue($0) < pingValue($1) }.prefix(10)), false)
        case .first:
            let s = pool.sorted { $0.cleanName(displayName($0)).localizedStandardCompare($1.cleanName(displayName($1))) == .orderedAscending }[0]
            return single(s)
        case .random:
            return single(pool.randomElement()!)
        }
    }

    func select(_ server: Server?) async {
        if let server {
            settings.selectedServerID = server.id; settings.selectedCountry = nil; settings.autoSelect = false
            if let code = server.countryCode { settings.lastServerByCountry[code] = server.id }
        }
        else { settings.autoSelect = true; settings.selectedCountry = nil }
        if isConnected { await connect() }
    }

    /// Клик по стране: подключиться к самому быстрому серверу этой страны (или переключиться на неё).
    func selectCountry(_ code: String) async {
        settings.selectedCountry = code; settings.selectedServerID = nil; settings.autoSelect = false
        await connect()
    }

    /// Клик по «Самый быстрый»: автовыбор и подключение.
    func selectFastest() async {
        settings.autoSelect = true; settings.selectedCountry = nil
        await connect()
    }

    struct Country: Identifiable {
        let id: String          // код страны
        let flag: String
        let name: String
        let servers: [Server]
        let bestPing: Int?
    }

    // MARK: избранное

    func isFavoriteCountry(_ code: String) -> Bool { settings.favoriteCountries.contains(code) }

    func toggleFavoriteCountry(_ code: String) {
        if let i = settings.favoriteCountries.firstIndex(of: code) { settings.favoriteCountries.remove(at: i) }
        else { settings.favoriteCountries.append(code) }
    }

    /// Избранные страны (по всем подпискам) — в порядке добавления.
    var favoriteCountryList: [Country] {
        let all = countries
        return settings.favoriteCountries.compactMap { code in all.first { $0.id == code } }
    }

    /// Избранные серверы — по алфавиту.
    var favoriteServerList: [Server] {
        usableServers.filter(\.favorite)
            .sorted { $0.cleanName(displayName($0)).localizedStandardCompare($1.cleanName(displayName($1))) == .orderedAscending }
    }

    /// Подписка (или «Добавленные вручную») — выпадающая группа серверов, внутри по странам.
    struct ServerGroup: Identifiable {
        let id: String
        let title: String
        let count: Int
        let countries: [Country]
        /// Те же серверы одним списком — для вида «Списком».
        let servers: [Server]
        let mode: GroupListMode
        let sort: GroupSort
        /// Подписку можно перетаскивать; «Добавленные вручную» всегда внизу.
        var movable: Bool { id != "manual" }
    }

    var serverGroups: [ServerGroup] {
        let usable = usableServers
        var out: [ServerGroup] = []
        func group(_ id: String, _ title: String, _ list: [Server]) -> ServerGroup {
            let (mode, sort) = layout(of: id)
            return ServerGroup(id: id, title: title, count: list.count, countries: countries(of: list, sort: sort),
                               servers: sortedServers(list, sort: sort), mode: mode, sort: sort)
        }
        for sub in subscriptions where sub.enabled {
            let list = usable.filter { $0.subscriptionID == sub.id }
            if !list.isEmpty { out.append(group(sub.id.uuidString, sub.name, list)) }
        }
        let known = Set(subscriptions.map(\.id))
        let manual = usable.filter { $0.subscriptionID.map { !known.contains($0) } ?? true }
        if !manual.isEmpty { out.append(group("manual", tr("Добавленные вручную"), manual)) }
        return out
    }

    // MARK: вид и порядок подписок в списке

    /// Вид и сортировка группы: у подписки — в ней самой, у «Добавленных вручную» — в UserDefaults.
    func layout(of groupID: String) -> (GroupListMode, GroupSort) {
        if let sub = subscriptions.first(where: { $0.id.uuidString == groupID }) {
            return (sub.listMode ?? .countries, sub.listSort ?? .name)
        }
        let d = UserDefaults.standard
        return (d.string(forKey: "tutun.manualListMode").flatMap(GroupListMode.init) ?? .countries,
                d.string(forKey: "tutun.manualListSort").flatMap(GroupSort.init) ?? .name)
    }

    func setLayout(of groupID: String, mode: GroupListMode? = nil, sort: GroupSort? = nil) {
        if let i = subscriptions.firstIndex(where: { $0.id.uuidString == groupID }) {
            if let mode { subscriptions[i].listMode = mode }
            if let sort { subscriptions[i].listSort = sort }
        } else {
            if let mode { UserDefaults.standard.set(mode.rawValue, forKey: "tutun.manualListMode") }
            if let sort { UserDefaults.standard.set(sort.rawValue, forKey: "tutun.manualListSort") }
            objectWillChange.send()
        }
    }

    /// Перетаскивание подписки на `target`: вниз — встаёт после неё, вверх — перед ней,
    /// на «Добавленные вручную» — в конец. (Раньше всегда «перед», и верхнюю нельзя было опустить на нижнюю.)
    func moveSubscription(_ dragged: String, onto target: String) {
        guard dragged != target, let from = subscriptions.firstIndex(where: { $0.id.uuidString == dragged }) else { return }
        let targetBefore = subscriptions.firstIndex { $0.id.uuidString == target }
        let item = subscriptions.remove(at: from)
        guard let t = subscriptions.firstIndex(where: { $0.id.uuidString == target }), let tb = targetBefore else {
            subscriptions.append(item); return
        }
        subscriptions.insert(item, at: from < tb ? t + 1 : t)
    }

    /// Избранное свёрнуто — как и подписки, помнится между запусками.
    @Published var favoritesCollapsed = UserDefaults.standard.bool(forKey: "tutun.favoritesCollapsed") {
        didSet { UserDefaults.standard.set(favoritesCollapsed, forKey: "tutun.favoritesCollapsed") }
    }

    /// Серверы одной группы списком.
    func sortedServers(_ list: [Server], sort: GroupSort) -> [Server] {
        switch sort {
        case .provider: return list   // порядок как в подписке
        case .ping: return list.sorted { pingValue($0) != pingValue($1) ? pingValue($0) < pingValue($1) : byName($0, $1) }
        case .name, .count: return list.sorted(by: byName)
        }
    }

    private func byName(_ a: Server, _ b: Server) -> Bool {
        a.cleanName(displayName(a)).localizedStandardCompare(b.cleanName(displayName(b))) == .orderedAscending
    }

    @Published var collapsedGroups: Set<String> = []
    /// Открыт ли список серверов справа (окно шире).
    /// Что выдвинуто справа в главном окне: серверы, настройки или ничего.
    @Published var sidePanel: SidePanel? = SidePanel(rawValue: UserDefaults.standard.string(forKey: "sidePanel")
                                                      ?? (UserDefaults.standard.bool(forKey: "showServers") ? "servers" : "")) {
        didSet { UserDefaults.standard.set(sidePanel?.rawValue ?? "", forKey: "sidePanel") }
    }
    var showServers: Bool { sidePanel == .servers }
    /// Открытый раздел в панели настроек (nil — список разделов).
    @Published var settingsPane: SettingsPane? {
        didSet { if let p = settingsPane, !p.inPanel { settingsPane = .general } }
    }

    func isCollapsed(_ id: String) -> Bool {
        if let sub = subscriptions.first(where: { $0.id.uuidString == id }) { return sub.collapsed }
        return collapsedGroups.contains(id)
    }

    func toggleCollapsed(_ id: String) {
        if let i = subscriptions.firstIndex(where: { $0.id.uuidString == id }) { subscriptions[i].collapsed.toggle(); return }
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }

    /// Страны из рабочих серверов, по алфавиту.
    var countries: [Country] { countries(of: usableServers) }

    func countries(of servers: [Server], sort: GroupSort = .name) -> [Country] {
        let groups = Dictionary(grouping: servers) { $0.countryCode ?? "??" }
        // Для «как у провайдера» — по первому серверу страны в подписке.
        var firstIndex: [String: Int] = [:]
        for (i, s) in servers.enumerated() where firstIndex[s.countryCode ?? "??"] == nil { firstIndex[s.countryCode ?? "??"] = i }
        return groups.map { code, list in
            let pings = list.compactMap { self.pings[$0.id] }.filter { $0 >= 0 }
            return Country(id: code, flag: list.first?.flag ?? "🌐", name: code == "??" ? tr("Другие") : Server.countryName(code),
                           servers: sortedServers(list, sort: sort == .count ? .name : sort),
                           bestPing: pings.min())
        }
        .sorted { a, b in
            if (a.id == "??") != (b.id == "??") { return b.id == "??" }
            let byName = a.name.localizedStandardCompare(b.name) == .orderedAscending
            switch sort {
            case .name: return byName   // по алфавиту — список не прыгает при обновлении задержек
            case .count: return a.servers.count != b.servers.count ? a.servers.count > b.servers.count : byName
            case .ping: return (a.bestPing ?? .max) != (b.bestPing ?? .max) ? (a.bestPing ?? .max) < (b.bestPing ?? .max) : byName
            case .provider: return (firstIndex[a.id] ?? 0) < (firstIndex[b.id] ?? 0)
            }
        }
    }

    /// Сервер, через который сейчас идёт VPN (или выбранный, если не подключено).
    var currentServer: Server? {
        if let n = activeServerName, let s = lastCandidates.first(where: { displayName($0) == n }) { return s }
        if !settings.autoSelect, settings.selectedCountry == nil { return selectedServer }
        return nil
    }

    /// Задержка до текущего сервера — та же величина, что в списке серверов.
    var currentLatency: Int? {
        if let s = currentServer, let p = pings[s.id], p >= 0 { return p }
        return nil
    }

    /// Название страны для крупного заголовка.
    var currentCountryName: String? {
        if let code = currentServer?.countryCode { return Server.countryName(code) }
        if !settings.autoSelect, let code = settings.selectedCountry { return Server.countryName(code) }
        if isConnected, let ip = ipVPN, !ip.country.isEmpty { return ip.country }
        return isConnected ? status.serverLabel : nil
    }

    var currentFlag: String? {
        if let f = currentServer?.flag { return f }
        if !settings.autoSelect, let c = settings.selectedCountry, let f = countries.first(where: { $0.id == c })?.flag { return f }
        return isConnected ? ipVPN?.flag : nil
    }

    /// Что выбрано для подключения — строкой.
    var selectionTitle: String {
        if settings.autoSelect { return tr("Самый быстрый") }
        if let code = settings.selectedCountry { return Server.countryName(code) }
        return selectedServer.map { displayName($0) } ?? tr("Самый быстрый")
    }

    func setMode(_ mode: ConnectionMode) async {
        guard mode != settings.mode else { return }
        settings.mode = mode
    }

    func setRoutingMode(_ m: RoutingMode) async {
        guard m != settings.routingMode else { return }
        settings.routingMode = m
    }

    // MARK: subscriptions

    var fetchOptions: FetchOptions {
        FetchOptions(hwid: appliedSettings.hwid, sendHWID: appliedSettings.sendHWID, userAgent: appliedSettings.userAgent, timeout: TimeInterval(max(5, appliedSettings.subTimeout)),
                     allowHTTP: appliedSettings.allowHttpSubscriptions)
    }

    func addSubscription(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("http") else { await importText(trimmed); return }
        guard !subscriptions.contains(where: { $0.url == trimmed }) else { message = tr("Такая подписка уже есть"); return }
        let sub = Subscription(name: "Подписка", url: trimmed)
        subscriptions.append(sub)
        await update(sub.id)
    }

    func update(_ id: UUID, ping: Bool = true) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        updatingSubs = true; defer { updatingSubs = false }
        let sub = subscriptions[idx]
        var migratedTo: String?
        do {
            let r = try await SubscriptionFetcher.fetch(sub, options: fetchOptions)
            let favs = Set(servers.filter(\.favorite).map(\.id))
            var fresh = r.servers
            for i in fresh.indices where favs.contains(fresh[i].id) { fresh[i].favorite = true }
            let others = servers.filter { $0.subscriptionID != id }
            if appliedSettings.ignoreDuplicates { fresh = dedupe(fresh, against: others) }
            servers = others + fresh
            if let j = subscriptions.firstIndex(where: { $0.id == id }) {
                subscriptions[j] = r.meta
                // Провайдер перенёс подписку (new-url / new-domain): дальше обновляемся с нового адреса.
                if let moved = r.newURL, !subscriptions.contains(where: { $0.url == moved }) {
                    subscriptions[j].url = moved
                    migratedTo = URL(string: moved)?.host
                }
            }
            // Профили маршрутов от провайдера заменяют прежние профили этой подписки.
            if !r.profiles.isEmpty {
                let oldProfileID = appliedSettings.activeProfileID
                let activeName = profiles.first { $0.id == oldProfileID }?.name
                profiles = profiles.filter { $0.fromSubscription != id } + r.profiles
                if let n = activeName, let p = profiles.first(where: { $0.name == n }) {
                    appliedSettings.activeProfileID = p.id
                    if settings.activeProfileID == oldProfileID { settings.activeProfileID = p.id }
                }
            }
            message = r.skipped.isEmpty ? nil : tr("Пропущено: \(r.skipped.count) — ") + r.skipped.prefix(2).joined(separator: "; ")
            if let host = migratedTo { message = tr("Провайдер перенёс подписку на новый адрес: \(host)") }
            checkExpiry(r.meta)
            if ping, appliedSettings.pingAfterUpdate { await pingGroup(id.uuidString) }
            // Переподключение нужно, только если серверы, с которыми работает служба, изменились.
            if isConnected, !lastCandidates.isEmpty {
                let current = Set(servers.map(\.id))
                if lastCandidates.contains(where: { !current.contains($0.id) }) { needsReconnect = true }
            }
        } catch {
            if let j = subscriptions.firstIndex(where: { $0.id == id }) { subscriptions[j].lastError = error.localizedDescription }
            message = error.localizedDescription
        }
    }

    private func dedupe(_ list: [Server], against others: [Server]) -> [Server] {
        var seen = Set(others.map { "\($0.proto)|\($0.host)|\($0.port)|\($0.outboundJSON.hashValue)" })
        return list.filter { seen.insert("\($0.proto)|\($0.host)|\($0.port)|\($0.outboundJSON.hashValue)").inserted }
    }

    func updateAll() async { for s in subscriptions { await update(s.id) } }

    private func updateDueSubscriptions(force: Bool = false, ping: Bool = true) async {
        for s in subscriptions where s.enabled {
            let due = force || (s.lastUpdate.map { Date().timeIntervalSince($0) > Double(s.updateIntervalHours) * 3600 } ?? true)
            if due { await update(s.id, ping: ping) }
        }
    }

    private func checkExpiry(_ s: Subscription) {
        let settings = appliedSettings
        guard settings.notifications, let exp = s.expire else { return }
        let days = Int(exp.timeIntervalSinceNow / 86400)
        guard days <= settings.expiryWarnDays else { return }
        if let last = lastExpiryWarn[s.id.uuidString], Date().timeIntervalSince(last) < 86400 { return }
        lastExpiryWarn[s.id.uuidString] = Date(); scheduleSave()
        Notifier.send(tr("Подписка «\(s.name)» заканчивается"), days <= 0 ? tr("Срок истёк") : tr("Осталось дней: \(days)"))
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        servers.removeAll { $0.subscriptionID == id }
        profiles.removeAll { $0.fromSubscription == id }
    }

    /// Ссылки серверов, профили маршрутов, base64-список, JSON, конфиг WireGuard, ссылки tutun://, happ://add.
    func importText(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { message = tr("Пусто"); return }
        for prefix in ["happ://add/", "tutun://add/", "tutun://import/"] where t.lowercased().hasPrefix(prefix) {
            let payload = String(t.dropFirst(prefix.count))
            let decoded = payload.removingPercentEncoding ?? payload
            if decoded.lowercased().hasPrefix("http") { await addSubscription(url: decoded); return }
            await importText(LinkParser.base64Decode(decoded) ?? decoded); return
        }
        if t.lowercased().hasPrefix("http"), !t.contains("\n") { await addSubscription(url: t); return }
        let b = LinkParser.parseBatch(Data(t.utf8), subscriptionID: nil)
        let known = Set(servers.map(\.id))
        var added = b.servers.filter { !known.contains($0.id) }
            if appliedSettings.ignoreDuplicates { added = dedupe(added, against: servers) }
        servers.append(contentsOf: added)
        for p in b.profiles { addProfile(p) }
        var parts: [String] = []
        if !added.isEmpty { parts.append(tr("серверов: \(added.count)")) }
        if !b.profiles.isEmpty { parts.append(tr("профилей маршрутов: \(b.profiles.count)")) }
        message = parts.isEmpty ? (b.errors.first ?? tr("Ничего не распознано")) : tr("Добавлено ") + parts.joined(separator: ", ") +
            (b.errors.isEmpty ? "" : tr(". Пропущено: \(b.errors.count)"))
        if !added.isEmpty { await pingAll() }
    }

    func importQR(_ codes: [String]) async {
        guard !codes.isEmpty else { message = tr("QR-код не найден"); return }
        await importText(codes.joined(separator: "\n"))
    }

    // MARK: servers

    func toggleFavorite(_ s: Server) { if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i].favorite.toggle() } }

    func remove(_ s: Server) {
        if s.subscriptionID == nil { servers.removeAll { $0.id == s.id } } else { hidden.insert(s.id) }
    }

    func rename(_ s: Server, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        settings.serverRenames[s.id] = n.isEmpty || n == s.name ? nil : n
    }

    /// Сохранить отредактированный сервер (ссылкой или JSON). Сервер из подписки становится ручной копией.
    func saveEdited(original: Server?, link: String?, json: String?, name: String) throws {
        var s: Server
        if let link, !link.isEmpty {
            s = try LinkParser.parse(link)
        } else if let json, let data = json.data(using: .utf8),
                  let ob = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let isSB = ob["type"] != nil && ob["protocol"] == nil
            let ep = isSB ? ((ob["server"] as? String) ?? "", (ob["server_port"] as? Int) ?? 0) : LinkParser.endpoint(of: ob)
            let proto = (ob["protocol"] as? String) ?? (ob["type"] as? String) ?? "?"
            s = Server(id: LinkParser.stableID(json), name: name, proto: proto, host: ep.0, port: ep.1,
                       transport: ((ob["streamSettings"] as? [String: Any])?["network"] as? String) ?? (isSB ? "quic" : "tcp"),
                       outboundJSON: LinkParser.toJSON(ob), engine: isSB ? .singbox : .xray)
        } else { throw LinkError.malformed(tr("пусто")) }
        if !name.isEmpty { s.name = name }
        s.favorite = original?.favorite ?? false
        if let o = original, o.subscriptionID == nil, let i = servers.firstIndex(where: { $0.id == o.id }) {
            servers[i] = s
        } else {
            servers.append(s)
        }
        if settings.selectedServerID == original?.id { settings.selectedServerID = s.id }
    }

    func removeDead() {
        let dead = servers.filter { (pings[$0.id] ?? 0) < 0 }
        for s in dead { remove(s) }
        message = dead.isEmpty ? tr("Нерабочих серверов нет") : tr("Убрано нерабочих серверов: \(dead.count)")
    }

    func unhideAll() { hidden.removeAll() }

    func link(for s: Server) -> String? { s.rawLink }

    func exportAllLinks() -> String {
        servers.compactMap(\.rawLink).joined(separator: "\n")
    }

    // MARK: ping / tests

    func pingAll() async { await ping(visibleServers) }

    /// Кнопки у подписки: «обновить» — только саму подписку, «проверить задержку» — только её серверы.
    @Published private(set) var refreshingGroup: String?
    @Published private(set) var pingingGroup: String?
    func refreshGroup(_ groupID: String) async {
        guard refreshingGroup == nil, let id = UUID(uuidString: groupID) else { return }
        refreshingGroup = groupID; defer { refreshingGroup = nil }
        await update(id, ping: false)
        // Обновление — один запрос к провайдеру, обычно меньше секунды: показываем итог, чтобы было видно, что оно было.
        if let sub = subscriptions.first(where: { $0.id == id }), sub.lastError == nil, message == nil {
            message = "\(sub.name): " + L10n.servers(servers.filter { $0.subscriptionID == id }.count)
        }
    }

    /// Проверка серверов одной подписки — не ждёт общую проверку и не мешает ей (у каждой свои порты).
    func pingGroup(_ groupID: String) async {
        guard pingingGroup == nil else { return }
        pingingGroup = groupID; defer { pingingGroup = nil }
        let known = Set(subscriptions.map(\.id.uuidString))
        let list = visibleServers.filter { s in
            groupID == "manual" ? !(s.subscriptionID.map { known.contains($0.uuidString) } ?? false) : s.subscriptionID?.uuidString == groupID
        }
        guard !list.isEmpty else { return }
        if appliedSettings.pingType == .url { await urlTest(list) } else { await tcpPing(list) }
    }

    func ping(_ list: [Server]) async {
        guard !testing, speedTesting == nil, !list.isEmpty else { return }
        testing = true; defer { testing = false }
        if appliedSettings.pingType == .url {
            await urlTest(list)
        } else {
            await tcpPing(list)
        }
    }

    func pingOne(_ s: Server) async {
        guard !testing, speedTesting == nil else { return }
        testing = true; defer { testing = false }
        if appliedSettings.pingType == .url { await urlTest([s]) } else { await tcpPing([s]) }
    }

    private func tcpPing(_ list: [Server]) async {
        let items = list.filter { !["hysteria2", "tuic", "wireguard"].contains($0.proto) }.map { ($0.id, $0.host, $0.port) }
        await withTaskGroup(of: (String, Int).self) { group in
            var it = items.makeIterator()
            func addNext() {
                guard let (id, host, port) = it.next() else { return }
                group.addTask { (id, await Pinger.tcp(host: host, port: port)) }
            }
            for _ in 0..<16 { addNext() }
            for await (id, ms) in group { pings[id] = ms; addNext() }
        }
        // Та же перепроверка для проверки соединением: не ответившие — ещё раз, по 4 за раз.
        let retry = items.filter { (pings[$0.0] ?? -1) < 0 }
        await withTaskGroup(of: (String, Int).self) { group in
            var it = retry.makeIterator()
            func addNext() {
                guard let (id, host, port) = it.next() else { return }
                group.addTask { (id, await Pinger.tcp(host: host, port: port)) }
            }
            for _ in 0..<4 { addNext() }
            for await (id, ms) in group { if ms >= 0 { pings[id] = ms }; addNext() }
        }
    }

    private func urlTest(_ list: [Server]) async {
        let settings = appliedSettings
        let usable = list.filter { LinkParser.rejectReason($0) == nil }
        for s in list where LinkParser.rejectReason(s) != nil { pings[s.id] = -1 }
        guard !usable.isEmpty else { return }
        do {
            let h = try await Tester.start(usable, settings: settings)
            defer { h.stop() }
            let url = settings.testURL, head = settings.testMethodHead, timeout = TimeInterval(max(2, settings.testTimeout))
            let items = usable.compactMap { s in h.ports[s.id].map { (s.id, $0) } }
            for s in usable where h.ports[s.id] == nil { pings[s.id] = -1 }
            await withTaskGroup(of: (String, Int).self) { group in
                var it = items.makeIterator()
                func addNext() {
                    guard let (id, port) = it.next() else { return }
                    group.addTask { (id, await Tester.delay(port: port, url: url, head: head, timeout: timeout)) }
                }
                for _ in 0..<10 { addNext() }
                for await (id, ms) in group { pings[id] = ms; addNext() }
            }
            // Перепроверка не ответивших по 2 за раз: при 10 одновременных проверках часть живых серверов
            // не успевает ответить. Замер на серверах пользователя 11.11.2026: «ожили» 7 из 24 и 3 из 19.
            // Приём из v2rayN (SpeedtestService.RunRealPingBatchAsync). Оценка меняется только на успешную.
            let retry = items.filter { (pings[$0.0] ?? -1) < 0 }
            await withTaskGroup(of: (String, Int).self) { group in
                var it = retry.makeIterator()
                func addNext() {
                    guard let (id, port) = it.next() else { return }
                    group.addTask { (id, await Tester.delay(port: port, url: url, head: head, timeout: timeout)) }
                }
                for _ in 0..<2 { addNext() }
                for await (id, ms) in group { if ms >= 0 { pings[id] = ms }; addNext() }
            }
        } catch {
            message = error.localizedDescription
            await tcpPing(list)
        }
    }

    func speedTest(_ s: Server) async {
        let settings = appliedSettings
        guard speedTesting == nil, !testing else { return }
        speedTesting = s.id; defer { speedTesting = nil }
        do {
            let h = try await Tester.start([s], settings: settings)
            defer { h.stop() }
            guard let port = h.ports[s.id] else { message = tr("Сервер не принят ядром"); return }
            if let bps = await Tester.speed(port: port) { speeds[s.id] = bps; message = "\(displayName(s)): \(formatMbps(bps))" }
            else { speeds[s.id] = 0; message = tr("\(displayName(s)): не удалось скачать тестовый файл") }
        } catch { message = error.localizedDescription }
    }

    // MARK: profiles

    func addProfile(_ p: RoutingProfile) {
        if let i = profiles.firstIndex(where: { $0.name == p.name && $0.fromSubscription == p.fromSubscription }) {
            var np = p; np.id = profiles[i].id; profiles[i] = np
        } else { profiles.append(p) }
        if settings.activeProfileID == nil { settings.activeProfileID = profiles.first { $0.name == p.name }?.id }
    }

    func activate(_ p: RoutingProfile?) async {
        settings.activeProfileID = p?.id
        if let g1 = p?.geoipURL, let g2 = p?.geositeURL { settings.geoipURL = g1; settings.geositeURL = g2 }
    }

    // MARK: IP, соединения, конфликты

    func checkIP() async {
        async let d = IPChecker.fetch(viaSocks: nil)
        // IP сервера — через вход проверки: он не подчиняется правилам «напрямую».
        async let v: IPInfo? = isConnected ? IPChecker.fetch(viaSocks: Paths.healthPort) : nil
        let (direct, vpn) = await (d, v)
        ipDirect = direct; ipVPN = vpn
    }

    func refreshConnections() async {
        guard watchConnections, isConnected, appliedSettings.mode == .tun else { if !connections.isEmpty && !isConnected { connections = [] }; return }
        if let c = await ConnectionsAPI.fetch(secret: clashSecret) {
            connections = c.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
        }
    }

    func closeConnection(_ id: String?) async {
        await ConnectionsAPI.close(id, secret: clashSecret)
        await refreshConnections()
    }

    func detectConflicts() -> [String] {
        var list = Conflicts.running().filter { $0 != "Happ" }
        if Conflicts.happCoreActive() { list.insert(tr("Happ (VPN включён)"), at: 0) }
        return list
    }

    // MARK: периодическое

    private func periodic() async {
        conflicts = detectConflicts()
        await Updater.shared.checkIfDue()
        await updateDueSubscriptions()
        if appliedSettings.geoAutoUpdate, daemonReachable,
           appliedSettings.geoLastUpdate.map({ Date().timeIntervalSince($0) > 7 * 86400 }) ?? true {
            await updateGeo(silent: true)
        }
    }

    func updateGeo(silent: Bool = false) async {
        guard daemonReachable, !daemonOutdated, !geoUpdateRequested, status.geoProgress == nil else { return }
        geoUpdateRequested = true
        geoUpdateError = nil
        defer { geoUpdateRequested = false }
        var req = DaemonRequest(cmd: .updateGeo)
        req.geoipURL = appliedSettings.geoipURL; req.geositeURL = appliedSettings.geositeURL
        do {
            let result = try await call(req, timeout: 480)
            if result.ok {
                settings.geoLastUpdate = Date()
                if !silent { message = tr("Гео-базы обновлены") }
            } else {
                geoUpdateError = result.error.map(trDynamic)
            }
        } catch { geoUpdateError = error.localizedDescription }
        await refreshStatus()
    }

    // MARK: ссылки tutun://

    /// Ссылка от другой программы или сайта (браузер, «Команды», Терминал). Включить VPN — сразу;
    /// отключить VPN и добавить серверы, подписку или профиль — только после подтверждения: иначе любая страница,
    /// которой однажды разрешили открывать Tutun, могла бы молча выключить VPN или подсунуть свою подписку.
    func handleExternalURL(_ url: URL) async {
        let scheme = url.scheme?.lowercased() ?? "", host = url.host?.lowercased() ?? ""
        if scheme == "tutun" {
            switch host {
            case "connect", "on", "debug":
                await handleURL(url); return
            case "disconnect", "off":
                if isConnected, confirmExternal(tr("Отключить VPN?"), tr("Команду отключения передала другая программа или сайт по ссылке tutun://."), tr("Отключить")) {
                    await disconnect()
                }
                return
            case "toggle":
                if !isConnected { await connect() }
                else if confirmExternal(tr("Отключить VPN?"), tr("Команду отключения передала другая программа или сайт по ссылке tutun://."), tr("Отключить")) {
                    await disconnect()
                }
                return
            default: break
            }
        }
        guard confirmExternal(tr("Добавить из ссылки?"), tr("Ссылку передала другая программа или сайт: \(Self.shortLink(url))"), tr("Добавить")) else { return }
        await handleURL(url)
    }

    private func confirmExternal(_ title: String, _ info: String, _ button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: tr("Отмена"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Что за ссылка — без ключей: адрес подписки без пути, у сервера только хост.
    static func shortLink(_ url: URL) -> String {
        let s = url.absoluteString
        for prefix in ["happ://add/", "tutun://add/", "tutun://import/"] where s.lowercased().hasPrefix(prefix) {
            let payload = String(s.dropFirst(prefix.count))
            if let u = URL(string: payload.removingPercentEncoding ?? payload), let h = u.host,
               let sc = u.scheme?.lowercased(), ["http", "https"].contains(sc) { return "\(sc)://\(h)/…" }
        }
        let scheme = url.scheme?.lowercased() ?? "", host = url.host ?? ""
        if ["tutun", "happ"].contains(scheme) { return "\(scheme)://\(host)/…" }
        return host.isEmpty ? "\(scheme)://…" : "\(scheme)://…@\(host)"
    }

    func handleURL(_ url: URL) async {
        let s = url.absoluteString
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "tutun" {
            let host = url.host?.lowercased() ?? ""
            switch host {
            case "connect", "on": await connect(); return
            case "disconnect", "off": await disconnect(); return
            case "toggle": await toggle(); return
            case "debug":
                // Служебные снимки окна — только если включены вручную (defaults write local.tutun.app
                // tutun.debugSnapshots -bool true): по ссылке из браузера они не должны срабатывать.
                guard UserDefaults.standard.bool(forKey: "tutun.debugSnapshots") else { return }
                if url.path.hasPrefix("/snapshot") { await Snapshot.run(query: url.query) }
                return
            case "routing":
                if s.lowercased().contains("/off") { await activate(nil); return }
                if let p = RoutingProfiles.parseLink(s) { addProfile(p); await activate(profiles.first { $0.name == p.name }); message = tr("Профиль «\(p.name)» добавлен") }
                return
            default: break
            }
        }
        if scheme == "happ", s.lowercased().hasPrefix("happ://routing") {
            if let p = RoutingProfiles.parseLink(s) { addProfile(p); message = tr("Профиль «\(p.name)» добавлен") }
            return
        }
        await importText(s)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: резервная копия

    func exportBackup(to url: URL) throws {
        let d = try JSONEncoder.tunnel.encode(store)
        try d.write(to: url, options: .atomic)
        chmod(url.path, 0o600)   // в копии ссылки подписок и ключи серверов
    }

    func importBackup(from url: URL) throws {
        let s = try JSONDecoder.tunnel.decode(Store.self, from: Data(contentsOf: url))
        let hwid = settings.hwid
        servers = s.servers; subscriptions = s.subscriptions; profiles = s.profiles
        var st = s.settings; st.hwid = hwid.isEmpty ? st.hwid : hwid   // ID устройства этого мака не меняем
        settings = st
        message = tr("Восстановлено: серверов \(s.servers.count), подписок \(s.subscriptions.count)")
    }

    func resetStats() { days = [:]; serverUsage = [:]; scheduleSave() }

    // MARK: install / login item

    func installDaemon() async {
        // Второй запрос пароля поверх идущей установки запустил бы два установщика сразу.
        guard !busy, daemonInstallStage == nil else { return }
        busy = true
        daemonInstallStage = daemonInstalled ? .updating : .installing
        defer { busy = false; daemonInstallStage = nil }
        do {
            try await Installer.install()
            daemonInstallStage = .starting
            // Что приложение знало о службе до установки, устарело: старая остановлена, а новая сначала
            // восстанавливает VPN и только потом открывает сокет (3–4 с). Без сброса при переустановке той же
            // версии «готово» показывалось сразу, а следом на пару секунд — кнопка «Обновить службу».
            daemonReachable = false
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await refreshStatus()
                if daemonReachable, !daemonOutdated { break }
            }
            if daemonReachable, !daemonOutdated {
                // «Готово» на месте кнопки пару секунд: кнопка не появляется под курсором сразу после установки,
                // и видно, что всё прошло.
                daemonInstallStage = .done
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            } else {
                message = tr("Служба установлена, но не отвечает — смотрите /var/log/tutun.log")
            }
        } catch { message = error.localizedDescription }
    }

    func uninstallDaemon() async {
        busy = true; defer { busy = false }
        do { try await Installer.uninstall(); await refreshStatus(); message = tr("Служба удалена") }
        catch { message = error.localizedDescription }
    }

    func setLaunchAtLogin(_ on: Bool) {
        settings.launchAtLogin = on
    }
}

enum Pinger {
    /// Время установки TCP-соединения с сервером, мс; -1 — недоступен.
    static func tcp(host: String, port: Int, timeout: TimeInterval = 3) async -> Int {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return -1 }
        let start = Date()
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        return await withCheckedContinuation { cont in
            let done = OnceFlag()
            @Sendable func finish(_ v: Int) { if done.set() { conn.cancel(); cont.resume(returning: v) } }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(Int(Date().timeIntervalSince(start) * 1000))
                case .failed, .cancelled, .waiting: finish(-1)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(-1) }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
