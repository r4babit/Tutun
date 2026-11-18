import Foundation
import AppKit
import CryptoKit
import TutunCore

/// Обновления из GitHub Releases: последняя версия → уведомление → скачать, проверить, заменить приложение, перезапустить.
/// Выпуск делает scripts/release.sh: в релизе лежат Tutun.zip, Tutun.zip.sha256, Tutun.zip.sig (подпись ключом автора)
/// и Tutun-release.json + .sig (манифест: какие версии отозваны).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "r4babit/Tutun"
    static var projectURL: URL { URL(string: "https://github.com/\(repo)")! }
    static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases")! }
    static let bundleID = "local.tutun.app"

    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        func asset(_ name: String) -> Asset? { assets.first { $0.name == name } }
    }

    enum State: Equatable {
        case idle, checking, upToDate, noReleases
        case available(Release)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Установленная версия отозвана манифестом выпуска: обновление настойчиво предлагается при каждой проверке.
    @Published private(set) var revoked = false
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "tutun.updateLastCheck") as? Date {
        didSet { UserDefaults.standard.set(lastCheck, forKey: "tutun.updateLastCheck") }
    }
    /// Как часто проверять сама: 1, 7, 14 или 30 дней.
    static let intervals = [1, 7, 14, 30]
    @Published var intervalDays: Int = {
        let v = UserDefaults.standard.integer(forKey: "tutun.updateIntervalDays")
        return Updater.intervals.contains(v) ? v : 1
    }() {
        didSet { UserDefaults.standard.set(intervalDays, forKey: "tutun.updateIntervalDays") }
    }
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "tutun.updateAutoCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "tutun.updateAutoCheck") }
    }

    var available: Release? { if case .available(let r) = state { return r }; return nil }
    var busy: Bool { state == .checking || state == .installing }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Сама — с выбранной частотой (при запуске и из периодической проверки), если не выключено.
    func checkIfDue() async {
        guard autoCheck, !busy else { return }
        if let l = lastCheck, Date().timeIntervalSince(l) < Double(intervalDays) * 24 * 3600 {
            // Срок ещё не подошёл — но найденное обновление должно быть видно и после перезапуска.
            if state == .idle { await check(userInitiated: false, notify: false) }
            return
        }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool, notify: Bool = true) async {
        guard !busy else { return }
        state = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Tutun/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            lastCheck = Date()
            let highest = UserDefaults.standard.integer(forKey: "tutun.releaseSequence")
            if code == 404 && highest == 0 { state = .noReleases; return }
            guard code == 200 else { throw Failure(tr("GitHub ответил ошибкой \(code)")) }
            let r = try JSONDecoder().decode(Release.self, from: data)
            guard r.asset("Tutun.zip") != nil, r.asset("Tutun.zip.sha256") != nil else {
                throw Failure(tr("В релизе \(r.tag_name) нет файла Tutun.zip"))
            }
            let manifest = await Self.manifest(of: r)
            let sequence = manifest?.sequence ?? 0
            let advertisesManifest = r.asset("Tutun-release.json") != nil || r.asset("Tutun-release.json.sig") != nil
            let accepts = manifest?.accepts(version: r.version, highestSequence: highest)
                ?? (!advertisesManifest && highest == 0)
            guard accepts else {
                throw Failure(tr("Не удалось проверить обновление"))
            }
            if sequence > highest { UserDefaults.standard.set(sequence, forKey: "tutun.releaseSequence") }
            guard AppVersion.isNewer(r.version, than: Self.currentVersion) else { state = .upToDate; revoked = false; return }
            revoked = manifest?.revokes(Self.currentVersion) ?? false
            state = .available(r)
            let key = "tutun.updateNotified"
            if revoked {
                // Отозванная версия: напоминаем при каждой проверке, а не один раз.
                if notify { Notifier.send(tr("Эта версия Tutun отозвана — установите обновление \(r.version)"),
                                          tr("VPN не отключится во время обновления. Установить — в «Настройки → О программе».")) }
            } else if notify, !userInitiated, UserDefaults.standard.string(forKey: key) != r.version {
                UserDefaults.standard.set(r.version, forKey: key)
                Notifier.send(tr("Доступно обновление Tutun \(r.version)"),
                              tr("VPN не отключится во время обновления. Установить — в «Настройки → О программе»."))
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Скачать, сверить контрольную сумму, проверить приложение, заменить себя и перезапуститься.
    func install() async {
        guard let r = available else { return }
        state = .installing
        do {
            let dest = Bundle.main.bundleURL
            guard dest.pathExtension == "app",
                  FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
                throw Failure(tr("Нет прав на запись в папку \(dest.deletingLastPathComponent().path)"))
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("tutun-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let zip = work.appendingPathComponent("Tutun.zip")
            let (tmp, zr) = try await URLSession.shared.download(from: r.asset("Tutun.zip")!.browser_download_url)
            guard (zr as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(tr("Не удалось скачать обновление")) }
            try FileManager.default.moveItem(at: tmp, to: zip)
            let (sumData, sr) = try await URLSession.shared.data(from: r.asset("Tutun.zip.sha256")!.browser_download_url)
            guard (sr as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(data: sumData, encoding: .utf8)?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
            else { throw Failure(tr("Не удалось скачать обновление")) }
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw Failure(tr("Контрольная сумма не совпала — файл повреждён")) }
            // Подпись ключом автора: сумма лежит в том же выпуске и от подмены файла не защищает.
            guard let sigAsset = r.asset("Tutun.zip.sig"),
                  let (sigData, sigResp) = try? await URLSession.shared.data(from: sigAsset.browser_download_url),
                  (sigResp as? HTTPURLResponse)?.statusCode == 200,
                  ReleaseSignature.verify(try Data(contentsOf: zip), signatureBase64: String(decoding: sigData, as: UTF8.self))
            else { throw Failure(tr("Подпись обновления не прошла проверку — файл не от автора Tutun")) }

            let unpacked = work.appendingPathComponent("app")
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let newApp = unpacked.appendingPathComponent("Tutun.app")
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Self.bundleID,
                  info?["CFBundleShortVersionString"] as? String == r.version else {
                throw Failure(tr("В архиве не то приложение"))
            }
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            try UpdateTrust.validate(newApp, against: dest)

            // Замену делает отдельный скрипт после выхода Tutun; если копирование не удалось — возвращает старую версию.
            let script = work.appendingPathComponent("swap.sh")
            let swap = Bundle.main.url(forResource: "update-swap", withExtension: "sh")
            guard let swap else { throw Failure("Update installer is missing") }
            try FileManager.default.copyItem(at: swap, to: script)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), dest.path, newApp.path, work.path, UUID().uuidString]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Манифест выпуска, только с верной подписью; без него или с чужой подписью — ничего не отзываем.
    private static func manifest(of r: Release) async -> ReleaseManifest? {
        guard let m = r.asset("Tutun-release.json"), let s = r.asset("Tutun-release.json.sig"),
              let (data, mr) = try? await URLSession.shared.data(from: m.browser_download_url), (mr as? HTTPURLResponse)?.statusCode == 200,
              let (sig, sr) = try? await URLSession.shared.data(from: s.browser_download_url), (sr as? HTTPURLResponse)?.statusCode == 200,
              data.count < 64 * 1024 else { return nil }
        return ReleaseManifest.verified(data, signatureBase64: String(decoding: sig, as: UTF8.self))
    }

    private nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure(tr("\(URL(fileURLWithPath: tool).lastPathComponent) завершился с ошибкой \(p.terminationStatus)"))
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }
}
