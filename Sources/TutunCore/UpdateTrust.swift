import Foundation
import Security

/// Кому доверять при обновлении приложения.
/// - Установленная сборка подписана Developer ID → новая обязана быть подписана той же командой (защита от взлома GitHub).
/// - Установленная сборка подписана локально (ad-hoc, сертификата нет — решение пользователя 08.11.2026) →
///   достаточно целой подписи codesign с идентификатором local.tutun.app; от подмены на GitHub защищает только
///   SHA-256 из того же выпуска. Служба (root) этим путём не обновляется — только кнопкой с паролем.
public enum UpdateTrust {
    public enum Policy: Equatable { case pinnedTeam(String), adHoc }
    /// Есть ли у установленной сборки команда Developer ID.
    public static func policy(for installed: URL) -> Policy {
        (try? team(at: installed)).map(Policy.pinnedTeam) ?? .adHoc
    }
    public enum Failure: Error { case untrusted }
    public static func team(at app: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.untrusted }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw Failure.untrusted }
        return team
    }
    public static func validate(_ app: URL, against installed: URL) throws {
        guard case .pinnedTeam(let pinned) = policy(for: installed) else {
            // Без сертификата: подпись должна быть целой и принадлежать именно Tutun.
            var code: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString("identifier \"local.tutun.app\"" as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess
            else { throw Failure.untrusted }
            return
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"" + pinned + "\" and identifier \"local.tutun.app\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else { throw Failure.untrusted }
    }
}
