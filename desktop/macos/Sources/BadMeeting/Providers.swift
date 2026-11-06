import Foundation

struct TranscriptionModel: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String
    init(id: String) { rawValue = id }
    init?(rawValue: String) {
        guard Edition.speechProviders.contains(where: { $0.id.rawValue == rawValue }) else { return nil }
        self.rawValue = rawValue
    }
    static let speechkit = Self(id: "yandex_speechkit")
    static let elevenLabs = Self(id: "elevenlabs")
    static var allCases: [Self] { Edition.speechProviders.map(\.id) }
    var id: String { rawValue }
    var provider: SpeechProvider { Edition.speechProviders.first { $0.id == self }! }
    var title: String { provider.title }
}

struct ElevenLabsSettings: Codable, Equatable, Sendable {
    var language = ""
    var diarize = true
}

struct SpeechProvider: Identifiable {
    let id: TranscriptionModel
    let title: String
    let credential: CredentialService
    var usesElevenLabsSettings = false
    let transcribe: (TranscriptionRequest) async throws -> Transcript
}

struct TranscriptionRequest {
    let meeting: Meeting
    let directory: URL
    let credentials: CredentialSettings
    let speechkit: SpeechKitSettings
    let elevenLabs: ElevenLabsSettings
    let progress: @Sendable (String) async -> Void
}

struct TextConnectionSettings: Codable, Equatable {
    var model: String
    var folderID = ""
    var baseURL = ""
}

struct TextModelSettings: Codable, Equatable {
    var providerID: String
    var connections: [String: TextConnectionSettings] = [:]
    var provider: TextProvider { Edition.textProviders.first { $0.id == providerID } ?? Edition.textProviders[0] }
    func connection(for provider: TextProvider) -> TextConnectionSettings { connections[provider.id] ?? provider.defaults }
    static func load(from defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: "BadMeeting.textModels"), let value = try? JSONDecoder().decode(Self.self, from: data) {
            var result = value
            if !Edition.textProviders.contains(where: { $0.id == result.providerID }) { result.providerID = Edition.textProviders[0].id }
            return result
        }
        return Edition.initialTextSettings(defaults)
    }
    func save(to defaults: UserDefaults) { defaults.set(try? JSONEncoder().encode(self), forKey: "BadMeeting.textModels") }
}

struct TextProvider: Identifiable {
    let id: String
    let title: String
    let credential: CredentialService?
    let defaults: TextConnectionSettings
    var usesFolderID = false
    var usesBaseURL = false
    var models: [String] = []
    var acceptsTranscript: (Transcript) -> Bool = { _ in true }
    var unwrapResponse = false
    var modelID: (TextConnectionSettings) -> String = { $0.model }
    let request: (TextConnectionSettings, String) throws -> URLRequest
}

enum PublicProviders {
    static let speech: [SpeechProvider] = [
        SpeechProvider(id: .speechkit, title: "Yandex SpeechKit (AI Studio)", credential: .speechkit) { context in
            return try await SpeechKitTranscriber(settings: context.speechkit).transcribe(meeting: context.meeting, directory: context.directory, credentials: context.credentials, progress: context.progress)
        },
        SpeechProvider(id: .elevenLabs, title: "ElevenLabs", credential: .elevenLabs, usesElevenLabsSettings: true) { context in
            let token = try await context.credentials.token(for: .elevenLabs)
            return try await ElevenLabsTranscriber(settings: context.elevenLabs).transcribe(meeting: context.meeting, directory: context.directory, token: token)
        }
    ]
    static let text: [TextProvider] = [
        TextProvider(id: "ai_studio", title: "Yandex AI Studio", credential: .aiStudio,
                     defaults: TextConnectionSettings(model: "yandexgpt/latest"), usesFolderID: true,
                     modelID: { "gpt://\($0.folderID)/\($0.model)" }) { settings, token in
            guard settings.folderID.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
                throw CredentialFailure(message: "Не задан корректный каталог AI Studio.")
            }
            var request = ProviderHTTP.request(url: URL(string: "https://ai.api.cloud.yandex.net/v1/chat/completions")!)
            request.setValue("Api-Key " + token, forHTTPHeaderField: "Authorization")
            request.setValue(settings.folderID, forHTTPHeaderField: "OpenAI-Project")
            return request
        },
        TextProvider(id: "openrouter", title: "OpenRouter", credential: .openRouter,
                     defaults: TextConnectionSettings(model: "openai/gpt-4o-mini")) { _, token in
            var request = ProviderHTTP.request(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        },
        TextProvider(id: "ollama", title: "Ollama", credential: nil,
                     defaults: TextConnectionSettings(model: "qwen3:8b", baseURL: "http://localhost:11434"), usesBaseURL: true) { settings, _ in
            guard let url = URL(string: settings.baseURL), let host = url.host,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
                throw CredentialFailure(message: "Для Ollama нужен локальный HTTP-адрес или адрес HTTPS.")
            }
            let base = url.path.hasSuffix("/v1") || url.path.hasSuffix("/v1/") ? url : url.appendingPathComponent("v1")
            return ProviderHTTP.request(url: base.appendingPathComponent("chat/completions"))
        }
    ]
}

enum ProviderHTTP {
    static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    static func session() -> URLSession { URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil) }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

enum ProviderResponse {
    static func data(_ data: Data, unwrap: Bool) throws -> Data {
        guard unwrap, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let response = object["response"] else { return data }
        return try JSONSerialization.data(withJSONObject: response)
    }
}
