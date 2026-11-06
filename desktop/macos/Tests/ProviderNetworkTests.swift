import Foundation
import AVFAudio
@testable import BadMeetingKit

final class ProviderFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct ProviderNetworkTests {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = 0.1 }
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("fixture.caf"), settings: format.settings)
        try file.write(from: buffer)
        let meeting = Meeting(id: UUID(), createdAt: Date(), title: "Fixture", status: .ready, sourceName: "Fixture",
            segments: [AudioSegment(id: UUID(), source: "fixture", fileName: "fixture.caf", startSeconds: 0, durationSeconds: 0.1)], transcript: nil, transcriptionError: nil)
        var uploads = 0
        ProviderFixtureProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
            precondition(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            uploads += 1
            return Data(#"{"text":"hello","words":[{"start":0,"end":0.1,"text":"hello","type":"word","speaker_id":"speaker_0"}]}"#.utf8)
        }
        let speech = try await ElevenLabsTranscriber(settings: ElevenLabsSettings(language: "eng", diarize: true), session: session()).transcribe(meeting: meeting, directory: root, token: "fixture-key")
        precondition(uploads == 1 && speech.words[0].speakerID == "speaker_0")
        let transcript = Transcript(text: "Я Мария.", words: [TranscriptWord(start: 0, end: 1, text: "Я Мария.", type: "word", speakerID: "speaker_0")], speakerNames: [:])
        for provider in PublicProviders.text {
            var credentials = CredentialSettings()
            if let service = provider.credential { credentials.legacyTokens[service.rawValue] = "fixture-key" }
            var settings = provider.defaults
            settings.folderID = "fixture-folder"
            var requests = 0
            ProviderFixtureProtocol.handler = { request in
                requests += 1
                let body: Data
                if let data = request.httpBody { body = data }
                else {
                    let stream = request.httpBodyStream!
                    stream.open(); defer { stream.close() }
                    var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
                    body = data
                }
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                precondition(json["model"] as? String == provider.modelID(settings))
                let speakers: [String: Any] = ["speakers": [["speaker_id": "speaker_0", "name": "Мария", "confidence": "high", "evidence": [["turn_id": 0, "quote": "Я Мария."]]]]]
                let content = String(decoding: try JSONSerialization.data(withJSONObject: speakers), as: UTF8.self)
                return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
            }
            let result = try await SpeakerResolver(provider: provider, configuration: settings, credentials: credentials, session: session()).resolve(transcript, event: nil)
            precondition(requests == 1 && result.names == ["speaker_0": "Мария"])
        }
        print("Direct ElevenLabs upload and all public text-provider requests passed with intercepted HTTP")
    }
}
