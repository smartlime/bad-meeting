import Foundation
import EventKit
@testable import BadMeetingKit

@main struct ProviderTests {
    @MainActor static func main() async throws {
        let suite = "BadMeeting-providers-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(!CredentialSettings.load(from: defaults).useAIW)
        var managed = CredentialSettings(useAIW: true)
        managed.aiwNames[CredentialService.elevenLabs.rawValue] = "CUSTOM_SPEECH_KEY"
        managed.save(to: defaults)
        precondition(CredentialSettings.load(from: defaults).keyName(for: .elevenLabs) == "CUSTOM_SPEECH_KEY")
        let inherited = try await managed.token(for: .elevenLabs, environment: ["CUSTOM_SPEECH_KEY": "fixture-inherited"], managedValue: { _ in fatalError() })
        precondition(inherited == "fixture-inherited")
        let resolved = try await managed.token(for: .openRouter, environment: [:], managedValue: { name in
            precondition(name == "OPENROUTER_API_KEY"); return "fixture-router"
        })
        precondition(resolved == "fixture-router")
        let saved = try await CredentialSettings().token(for: .elevenLabs, environment: ["ELEVENLABS_API_KEY": "ignored"], managedValue: { _ in fatalError() }, storedValue: { service in
            precondition(service == .elevenLabs); return "fixture-manual"
        })
        precondition(saved == "fixture-manual")
        do {
            _ = try await CredentialSettings().token(for: .openRouter, environment: ["OPENROUTER_API_KEY": "ignored"], storedValue: { _ in "" })
            fatalError("Empty manual credentials must not fall back")
        } catch is CredentialFailure {}
        precondition(CredentialSettings.masked("abc-test-xyz") == "abc...xyz")
        precondition(CredentialSettings.masked("short") == "***" && CredentialSettings.masked("").isEmpty)

        let legacy = CredentialService(rawValue: "fixture", environmentKey: "FIXTURE_KEY", legacyDefaultsKey: "fixture-old")
        defaults.set("fixture-value", forKey: "fixture-old")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: temp) }
        let model = AppModel(storeRoot: temp, credentialsDefaults: defaults, calendarProvider: OfflineCalendarFixture(), credentialWriter: { _, _ in throw CredentialFailure(message: "fixture") })
        model.credentials.legacyTokens[legacy.rawValue] = "fixture-value"
        do { try await model.saveCredential("new-fixture", for: legacy); fatalError() } catch is CredentialFailure {}
        precondition(defaults.string(forKey: "fixture-old") == "fixture-value")
        let successful = AppModel(storeRoot: temp, credentialsDefaults: defaults, calendarProvider: OfflineCalendarFixture(), credentialWriter: { value, service in
            precondition(value == "new-fixture" && service == legacy)
        })
        successful.credentials.legacyTokens[legacy.rawValue] = "fixture-value"
        try await successful.saveCredential("new-fixture", for: legacy)
        precondition(defaults.string(forKey: "fixture-old") == nil && successful.credentials.legacyToken(for: legacy).isEmpty)

        let studio = PublicProviders.text[0]
        let settings = TextConnectionSettings(model: "yandexgpt/latest", folderID: "fixture-folder")
        let request = try studio.request(settings, "fixture-key")
        precondition(request.url?.absoluteString == "https://ai.api.cloud.yandex.net/v1/chat/completions")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Api-Key fixture-key")
        precondition(request.value(forHTTPHeaderField: "OpenAI-Project") == "fixture-folder")
        precondition(studio.modelID(settings) == "gpt://fixture-folder/yandexgpt/latest")
        let router = try PublicProviders.text[1].request(PublicProviders.text[1].defaults, "fixture-key")
        precondition(router.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        precondition(router.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        let ollama = PublicProviders.text[2]
        let local = try ollama.request(ollama.defaults, "")
        precondition(local.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        precondition(local.value(forHTTPHeaderField: "Authorization") == nil)
        for address in ["http://example.test", "file:///tmp/model", "https://user:password@example.test", "https://example.test?key=secret"] {
            do { _ = try ollama.request(TextConnectionSettings(model: "fixture", baseURL: address), ""); fatalError("Unsafe endpoint") }
            catch is CredentialFailure {}
        }
        let payload = try JSONSerialization.jsonObject(with: SpeakerResolver.requestBody(turns: [], candidates: [], model: "fixture-model")) as! [String: Any]
        precondition(payload["model"] as? String == "fixture-model")
        let fakeStore = EKEventStore()
        let event = EKEvent(eventStore: fakeStore)
        let calendar = EKCalendar(for: .event, eventStore: fakeStore)
        event.calendar = calendar
        event.title = "Fixture"
        event.startDate = Date(timeIntervalSince1970: 10000)
        event.endDate = Date(timeIntervalSince1970: 11000)
        event.notes = "https://zoom.us/j/123"
        let converted = SystemCalendarProvider.convert(event)
        precondition(converted.title == "Fixture" && converted.sourceID == "system" && converted.detailsLoaded)
        precondition(converted.calls.count == 1 && converted.remoteID.hasPrefix("system:"))
        print("Provider routing, credential isolation, migration, masking, endpoint validation and EventKit mapping passed")
    }
}
