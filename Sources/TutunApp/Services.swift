import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UserNotifications
import Network
import TutunCore

// MARK: - Уведомления

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func send(_ title: String, _ body: String = "") {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - IP и страна

struct IPInfo: Equatable {
    var ip: String
    var country: String
    var flag: String
    var city: String
    var org: String
}

enum IPChecker {
    /// via: socks-порт (через VPN) или nil (напрямую — сам Tutun в режиме TUN идёт мимо VPN).
    static func fetch(viaSocks port: Int?) async -> IPInfo? {
        let s: URLSession
        if let port { s = Tester.session(port: port, timeout: 10) }
        else { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 10; c.connectionProxyDictionary = [:]; s = URLSession(configuration: c) }
        defer { s.invalidateAndCancel() }
        guard let url = URL(string: "https://ipwho.is/?lang=ru"),
              let (data, _) = try? await s.data(from: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (o["success"] as? Bool) != false else { return nil }
        return IPInfo(ip: o["ip"] as? String ?? "?", country: o["country"] as? String ?? "",
                      flag: (o["flag"] as? [String: Any])?["emoji"] as? String ?? "",
                      city: o["city"] as? String ?? "", org: (o["connection"] as? [String: Any])?["org"] as? String ?? "")
    }
}

// MARK: - Соединения (sing-box clash API, режим «Весь трафик»)

struct Conn: Identifiable, Equatable {
    var id: String
    var host: String
    var process: String
    var network: String
    var route: String
    var upload: Int64
    var download: Int64
    var start: Date?
}

enum ConnectionsAPI {
    static func fetch(secret: String) async -> [Conn]? {
        guard let url = URL(string: "http://127.0.0.1:\(Paths.clashPort)/connections") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (o["connections"] as? [[String: Any]] ?? []).map { c in
            let m = c["metadata"] as? [String: Any] ?? [:]
            let host = (m["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(m["destinationIP"] ?? "")"
            let port = "\(m["destinationPort"] ?? "")"
            let proc = ((m["processPath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? ""
            let chains = (c["chains"] as? [String])?.first ?? ""
            return Conn(id: c["id"] as? String ?? UUID().uuidString, host: port.isEmpty ? host : "\(host):\(port)",
                        process: proc, network: (m["network"] as? String ?? "").uppercased(),
                        route: chains == "direct" ? tr("напрямую") : tr("через VPN"),
                        upload: (c["upload"] as? NSNumber)?.int64Value ?? 0, download: (c["download"] as? NSNumber)?.int64Value ?? 0,
                        start: (c["start"] as? String).flatMap { iso.date(from: $0) })
        }
    }

    static func close(_ id: String?, secret: String) async {
        let path = id.map { "/connections/\($0)" } ?? "/connections"
        guard let url = URL(string: "http://127.0.0.1:\(Paths.clashPort)\(path)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 3); req.httpMethod = "DELETE"
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - QR

enum QR {
    static func image(_ text: String, size: CGFloat = 260) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }

    static func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func decode(file: URL) -> [String] {
        guard let img = NSImage(contentsOf: file), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return decode(cg)
    }

    static func decodeClipboard() -> [String] {
        guard let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return decode(cg)
    }

    /// Снимок всех экранов (macOS спросит разрешение «Запись экрана») и поиск QR-кодов.
    static func scanScreen() -> [String] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tutun-qr-\(UUID().uuidString).png")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-t", "png", tmp.path]
        try? p.run(); p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: tmp) }
        return decode(file: tmp)
    }
}

// MARK: - Другие VPN, которые мешают

enum Conflicts {
    static let known = ["Happ", "v2rayN", "Hiddify", "ClashX", "ClashX Pro", "Clash Verge", "FlClash", "Outline", "AmneziaVPN",
                        "NordVPN", "ExpressVPN", "Surfshark", "Proton VPN", "Streisand", "V2Box", "FoXray", "v2RayTun", "INCY",
                        "incy", "Shadowrocket", "Mullvad VPN", "WireGuard", "Tailscale", "Karing", "NekoRay", "Sing-box", "SFM"]

    static func running() -> [String] {
        let names = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
        return known.filter { names.contains($0) }
    }

    /// Happ держит свою службу всегда, но мешает только когда запущено его ядро.
    static func happCoreActive() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "Happ.app/Contents/MacOS/core/xray"]
        p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Байты по-русски: 0 Б, 512 Б, 1,4 КБ, 23 МБ, 5,9 ГБ.
func formatBytes(_ b: Int64) -> String {
    let units = [tr("Б"), tr("КБ"), tr("МБ"), tr("ГБ"), tr("ТБ")]
    var v = Double(max(b, 0)), i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    let num = i == 0 || v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    return "\(num) \(units[i])"
}
func formatSpeed(_ bps: Double) -> String { formatBytes(Int64(bps)) + tr("/с") }
func formatMbps(_ bps: Double) -> String { String(format: tr("%.1f Мбит/с"), bps * 8 / 1_000_000) }
