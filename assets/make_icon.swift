// Собирает выбранный значок из исходника в PNG и ICNS, не меняя его рисунок.
// Запуск: swift assets/make_icon.swift [путь к icon_1024.png]
import Foundation

let assets = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
let source = assets.appendingPathComponent("icon_tunnel_source.png")
let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? assets.appendingPathComponent("icon_1024.png")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Tutun-\(UUID()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "Tutun.Icon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "Не удалось собрать значок: \(executable)"])
    }
}
try run("/usr/bin/sips", ["-z", "1024", "1024", source.path, "--out", output.path])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = String(size * scale)
        let suffix = scale == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try run("/usr/bin/sips", ["-z", pixels, pixels, source.path, "--out", file.path])
    }
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path])
print("Собран значок Tutun: тоннель со светом в конце")
