@testable import BadMeetingKit
import Foundation

final class SpeechKitFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct SpeechKitTests {
    static let raw = #"{"result":{"audioCursors":{"finalIndex":"0"},"final":{"alternatives":[{"text":"привет мир","words":[{"text":"привет","startTimeMs":"100","endTimeMs":"400"},{"text":"мир","startTimeMs":"500","endTimeMs":"900"}]}],"channelTag":"1"}}}"#
    static let normalized = #"{"result":{"finalRefinement":{"finalIndex":"0","normalizedText":{"alternatives":[{"text":"Привет, мир.","startTimeMs":"100","endTimeMs":"900"}],"channelTag":"1"}}}}"#
    static func main() async throws {
        let response = Data((raw + "\n" + normalized).utf8)
        let parsed = try SpeechKitTranscriber.parseResponse(response, offset: 1200, speakerPrefix: "часть_2_", speakerLabeling: true)
        precondition(parsed.words.count == 1 && parsed.text == "Привет, мир.")
        precondition(parsed.words[0].start == 1200.1 && parsed.words[0].end == 1200.9)
        precondition(parsed.words[0].speakerID == "часть_2_диктор_1")
        precondition(parsed.transcriptionProvider == TranscriptionModel.speechkit.rawValue)
        let reversed = try SpeechKitTranscriber.parseResponse(Data((normalized + "\n" + raw).utf8))
        precondition(reversed.text == "Привет, мир.")
        for invalid in ["", "{}", "{", raw + "truncated", #"{"error":{"code":13,"message":"private transcript"}}"#] {
            do {
                _ = try SpeechKitTranscriber.parseResponse(Data(invalid.utf8))
                fatalError("Malformed/failed results must be rejected")
            } catch { precondition(!error.localizedDescription.contains("private transcript")) }
        }
        let topChannel = try SpeechKitTranscriber.parseResponse(Data(#"{"result":{"channelTag":"1","final":{"alternatives":[{"text":"Тест","startTimeMs":"0","endTimeMs":"10"}]},"audioCursors":{"finalIndex":"0"}}}"#.utf8), speakerLabeling: true)
        precondition(topChannel.words.first?.speakerID == "диктор_1")
        let silent = try SpeechKitTranscriber.parseResponse(Data(#"{"result":{"sessionUuid":{"uuid":"fixture"},"final":{"alternatives":[{"text":""}]}}}"#.utf8))
        precondition(silent.words.isEmpty)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechKitFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let settings = SpeechKitSettings(folderID: "fixture-folder", language: "", speakerLabeling: true)
        var transcriber = SpeechKitTranscriber(settings: settings, session: session, pollDelay: .zero)
        transcriber.chunkBytes = 8
        let body = try JSONSerialization.jsonObject(with: transcriber.requestBody(audio: Data([1, 2]))) as! [String: Any]
        precondition(body["content"] as? String == "AQI=")
        precondition(body["summarization"] == nil && body["uri"] == nil)
        let recognition = body["recognitionModel"] as! [String: Any]
        precondition(recognition["languageRestriction"] == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speechkit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var wave = Data(repeating: 0, count: 60)
        wave.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        wave.replaceSubrange(36..<40, with: Data("data".utf8))
        let audio = root.appendingPathComponent("fixture.wav")
        try wave.write(to: audio)
        var posts = 0
        var failResult = true
        var reads = 0
        SpeechKitFixtureProtocol.handler = { request in
            precondition(["stt.api.cloud.yandex.net", "operation.api.cloud.yandex.net"].contains(request.url!.host!))
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Api-Key fixture-secret")
            precondition(request.value(forHTTPHeaderField: "x-data-logging-enabled") == "false")
            precondition(request.value(forHTTPHeaderField: "x-folder-id") == "fixture-folder")
            if request.httpMethod == "POST" {
                posts += 1
                return (200, Data("{\"id\":\"operation-\(posts)\"}".utf8))
            }
            if request.url!.host == "operation.api.cloud.yandex.net" { return (200, Data(#"{"done":true}"#.utf8)) }
            reads += 1
            if failResult { throw URLError(.networkConnectionLost) }
            return (200, response)
        }
        do {
            _ = try await transcriber.transcribe(wave: audio, directory: root, token: "fixture-secret")
            fatalError("Expected a simulated read failure")
        } catch { precondition(!error.localizedDescription.contains("fixture-secret")) }
        precondition(posts == 1 && reads == 3)
        let checkpointURL = root.appendingPathComponent(SpeechKitTranscriber.checkpointName)
        let checkpoint = try Data(contentsOf: checkpointURL)
        precondition(!String(decoding: checkpoint, as: UTF8.self).contains("fixture-secret"))
        failResult = false
        let completed = try await transcriber.transcribe(wave: audio, directory: root, token: "fixture-secret")
        precondition(posts == 2, "Resuming must not submit the accepted first chunk again")
        precondition(completed.words.count == 2 && completed.words[1].start == 0.10025)
        precondition(completed.words[0].speakerID != completed.words[1].speakerID)
        precondition(completed.wordWarning != nil)
        SpeechKitTranscriber.clearCheckpoint(in: root)
        precondition(!FileManager.default.fileExists(atPath: checkpointURL.path))
        posts = 0
        SpeechKitFixtureProtocol.handler = { request in
            if request.httpMethod == "POST" { posts += 1 }
            throw URLError(.timedOut)
        }
        do {
            _ = try await transcriber.transcribe(wave: audio, directory: root, token: "fixture-secret")
            fatalError("Expected upload error")
        } catch { precondition(!TranscriptionError.isRetryableNetworkFailure(error)) }
        precondition(posts == 1, "An uncertain POST must never retry automatically")
        print("SpeechKit tests passed: request contract, privacy headers, parsing/refinement, timestamps, invalid responses, chunk identity, read retry, checkpoint resume, uncertain upload")
    }
}
