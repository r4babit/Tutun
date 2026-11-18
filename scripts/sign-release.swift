#!/usr/bin/env swift
// Подпись выпусков Tutun ключом Ed25519. Закрытый ключ лежит только в «Связке ключей» этого мака
// (запись «tutun-release-signing»), в проект и на экран не попадает. Открытый ключ вшит в приложение
// (Sources/TutunCore/ReleaseSignature.swift): обновление без верной подписи Tutun не установит.
//
//   swift scripts/sign-release.swift keygen            — создать ключ (один раз), напечатать открытый
//   swift scripts/sign-release.swift pubkey            — напечатать открытый ключ
//   swift scripts/sign-release.swift sign <файл>       — записать <файл>.sig (base64)
//   swift scripts/sign-release.swift manifest <версия> <мин.версия|-> <отозванные через запятую|-> <куда>
//
// Потеря ключа = будущие обновления не пройдут проверку (понадобится ручная установка новой сборки
// с новым ключом). Сохраните копию: «Связка ключей» → «tutun-release-signing» → показать пароль.
import CryptoKit
import Foundation

let service = "tutun-release-signing", account = "ed25519"

func security(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func die(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

func loadKey() -> Curve25519.Signing.PrivateKey {
    let (code, text) = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard code == 0, let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        die("Нет ключа подписи в «Связке ключей» (\(service)). Создайте: swift scripts/sign-release.swift keygen")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    if security(["find-generic-password", "-s", service, "-a", account]).0 == 0 { die("Ключ уже есть. Удалять и создавать заново нельзя: старые сборки перестанут принимать обновления.") }
    let key = Curve25519.Signing.PrivateKey()
    let (code, _) = security(["add-generic-password", "-s", service, "-a", account, "-l", "Tutun: подпись выпусков",
                              "-T", "/usr/bin/security", "-w", key.rawRepresentation.base64EncodedString()])
    guard code == 0 else { die("Не удалось сохранить ключ в «Связку ключей»") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "pubkey":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]) else { die("sign <файл>") }
    guard let signature = try? loadKey().signature(for: data) else { die("Не удалось подписать") }
    do { try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: args[1] + ".sig")) } catch { die("Не записать подпись") }
case "manifest":
    guard args.count == 5 else { die("manifest <версия> <мин.версия|-> <отозванные|-> <куда>") }
    var object: [String: Any] = ["version": args[1], "blocked": args[3] == "-" ? [] : args[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }]
    // Повторная сборка в ту же секунду или перевод часов назад не понижает номер.
    let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TutunRelease")
    do {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let lock = open(stateDir.appendingPathComponent("sequence.lock").path, O_WRONLY | O_CREAT, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else { die("Не получить блокировку номера выпуска") }
        defer { close(lock) }
        let counter = stateDir.appendingPathComponent("sequence")
        var previous = 0
        if FileManager.default.fileExists(atPath: counter.path) {
            let saved = try String(contentsOf: counter, encoding: .utf8)
            guard let value = Int(saved), value >= 0, value < Int.max else { die("Повреждён номер выпуска") }
            previous = value
        }
        let sequence = max(previous + 1, Int(Date().timeIntervalSince1970))
        try String(sequence).write(to: counter, atomically: true, encoding: .utf8)
        object["sequence"] = sequence
    } catch { die("Не сохранить номер выпуска: \(error.localizedDescription)") }
    if args[2] != "-" { object["minimumVersion"] = args[2] }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else { die("Не собрать манифест") }
    do { try data.write(to: URL(fileURLWithPath: args[4])) } catch { die("Не записать манифест") }
default:
    die("Использование: keygen | pubkey | sign <файл> | manifest <версия> <мин|-> <отозванные|-> <куда>")
}
