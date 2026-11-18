import CryptoKit
import Foundation

/// Подпись выпусков ключом автора (Ed25519), независимо от сертификата Apple и от GitHub.
/// Закрытый ключ — в «Связке ключей» мака автора (scripts/sign-release.swift), здесь только открытый.
/// SHA-256 из того же выпуска защищает от битого файла; подпись — от подмены файла теми, у кого нет ключа
/// (в том числе при взломе аккаунта GitHub). Приём из Clash Verge Rev (minisign в tauri.conf.json).
public enum ReleaseSignature {
    /// Открытый ключ, raw 32 байта в base64. Менять нельзя: сборки со старым ключом перестанут принимать обновления.
    public static let publicKeyBase64 = "jnLRMeUWS4AYxicPiEtfhkaWTwL0Iu1dCcJuJst3dj0="

    public static func verify(_ data: Data, signatureBase64: String, publicKeyBase64: String = publicKeyBase64) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// Манифест выпуска (Tutun-release.json, подписан тем же ключом): какие версии отозваны.
/// Нужен, чтобы настойчиво обновить сборку, в которой нашли серьёзную ошибку (как блок-лист в манифесте Happ).
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public var version: String
    /// Всё, что старше, считается отозванным.
    public var sequence: Int?
    public var minimumVersion: String?
    /// Отдельные отозванные версии.
    public var blocked: [String]

    public init(version: String, minimumVersion: String? = nil, blocked: [String] = []) {
        self.version = version; self.minimumVersion = minimumVersion; self.blocked = blocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence)
        minimumVersion = try c.decodeIfPresent(String.self, forKey: .minimumVersion)
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
    }

    /// Старые выпуски без счётчика допустимы до первого принятого нумерованного выпуска.
    public func accepts(version releaseVersion: String, highestSequence: Int) -> Bool {
        version == releaseVersion && (sequence ?? 0) >= highestSequence
    }

    /// Отозвана ли установленная версия. Манифест от более старого выпуска, чем установленная сборка, ничего не отзывает.
    public func revokes(_ current: String) -> Bool {
        func same(_ a: String, _ b: String) -> Bool { !AppVersion.isNewer(a, than: b) && !AppVersion.isNewer(b, than: a) }
        guard AppVersion.isNewer(version, than: current) else { return false }
        if let minimumVersion, AppVersion.isNewer(minimumVersion, than: current) { return true }
        return blocked.contains { same($0, current) }
    }

    /// Разбор только после проверки подписи.
    public static func verified(_ data: Data, signatureBase64: String, publicKeyBase64: String = ReleaseSignature.publicKeyBase64) -> ReleaseManifest? {
        guard ReleaseSignature.verify(data, signatureBase64: signatureBase64, publicKeyBase64: publicKeyBase64) else { return nil }
        return try? JSONDecoder().decode(ReleaseManifest.self, from: data)
    }
}
