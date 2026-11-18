import Foundation
import TutunShared

public enum SettingsPolicy {
    /// Действия со списком серверов не подтверждают остальные изменённые настройки.
    public static func mergingRuntimeChanges(from old: AppSettings, to draft: AppSettings, accepted: AppSettings) -> AppSettings {
        var result = accepted
        if old.selectedServerID != draft.selectedServerID { result.selectedServerID = draft.selectedServerID }
        if old.selectedCountry != draft.selectedCountry { result.selectedCountry = draft.selectedCountry }
        if old.autoSelect != draft.autoSelect { result.autoSelect = draft.autoSelect }
        if old.lastServerByCountry != draft.lastServerByCountry { result.lastServerByCountry = draft.lastServerByCountry }
        if old.favoriteCountries != draft.favoriteCountries { result.favoriteCountries = draft.favoriteCountries }
        if old.serverRenames != draft.serverRenames { result.serverRenames = draft.serverRenames }
        if old.sort != draft.sort { result.sort = draft.sort }
        if old.geoLastUpdate != draft.geoLastUpdate { result.geoLastUpdate = draft.geoLastUpdate }
        return result
    }
}
