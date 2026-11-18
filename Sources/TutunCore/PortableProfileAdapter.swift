import Foundation
import TutunShared

/// Переход между текущими моделями macOS и общим форматом. Не читает и не меняет файлы пользователя.
public enum PortableProfileAdapter {
    public static func makeProfile(servers: [Server], subscriptions: [Subscription], routingProfiles: [RoutingProfile],
                                   acceptedSettings: AppSettings) throws -> ConfigurationProfile {
        let settingsData = try JSONEncoder.tunnel.encode(acceptedSettings)
        let preferences = try JSONDecoder.tunnel.decode(ConnectionPreferences.self, from: settingsData)
        let profile = ConfigurationProfile(servers: servers, subscriptions: subscriptions,
                                           routingProfiles: routingProfiles, preferences: preferences)
        try profile.validate()
        return profile
    }

    /// Переносит только общие поля; локальные права, HWID, приложения и UI остаются на устройстве.
    public static func applying(_ preferences: ConnectionPreferences, to local: AppSettings) throws -> AppSettings {
        try preferences.validate()
        let encoder = JSONEncoder.tunnel
        guard var object = try JSONSerialization.jsonObject(with: encoder.encode(local)) as? [String: Any],
              let common = try JSONSerialization.jsonObject(with: encoder.encode(preferences)) as? [String: Any] else {
            throw ConfigurationProfile.Failure(tr("Не удалось прочитать настройки"))
        }
        // Отсутствующие nullable-ссылки должны очищать прежний выбор.
        object.removeValue(forKey: "chainServerID")
        object.removeValue(forKey: "activeProfileID")
        object.merge(common) { _, imported in imported }
        return try JSONDecoder.tunnel.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
