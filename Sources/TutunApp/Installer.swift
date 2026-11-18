import Foundation
import TutunCore

/// Установка службы: скрипт из ресурсов приложения запускается с правами администратора
/// (macOS сама спрашивает пароль). Ядра копируются в каталог root, чтобы их нельзя было подменить без пароля.
enum Installer {
    struct Failure: LocalizedError { let errorDescription: String? }

    static func install() async throws {
        guard let res = Bundle.main.resourcePath else { throw Failure(errorDescription: tr("Нет ресурсов приложения")) }
        try await runAdmin(script: res + "/install.sh", args: [res, String(getuid())])
    }

    static func uninstall() async throws {
        guard let res = Bundle.main.resourcePath else { throw Failure(errorDescription: tr("Нет ресурсов приложения")) }
        try await runAdmin(script: res + "/uninstall.sh", args: [])
    }

    private static func runAdmin(script: String, args: [String]) async throws {
        guard FileManager.default.fileExists(atPath: script) else {
            throw Failure(errorDescription: tr("Не найден \(script). Запускайте собранное приложение Tutun.app"))
        }
        let cmd = (["/bin/bash", script] + args).map(shellQuote).joined(separator: " ")
        let source = "do shell script \(appleQuote(cmd)) with administrator privileges"
        try await Task.detached {
            var err: NSDictionary?
            let s = NSAppleScript(source: source)
            _ = s?.executeAndReturnError(&err)
            if let err {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "\(err)"
                if (err[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure(errorDescription: tr("Отменено")) }
                throw Failure(errorDescription: msg)
            }
        }.value
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
