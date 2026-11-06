import Foundation

enum Edition {
    static let speechProviders = PublicProviders.speech
    static let textProviders = PublicProviders.text
    static var credentialServices: [CredentialService] {
        Array(Set(speechProviders.map(\.credential) + textProviders.compactMap(\.credential) + calendarSources.compactMap(\.credential)))
    }
    static let calendarSources = [CalendarSource.system]
    static let defaultCalendarConnected = false
    static func initialTextSettings(_ defaults: UserDefaults) -> TextModelSettings {
        TextModelSettings(providerID: textProviders[0].id)
    }
    static func additionalVideoProvider(_ url: URL) -> String? { nil }
}
