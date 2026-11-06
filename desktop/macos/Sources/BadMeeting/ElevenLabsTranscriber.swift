import Foundation

struct ElevenLabsTranscriber {
    var settings = ElevenLabsSettings()
    var endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    var authorizationHeader = "xi-api-key"
    var authorizationPrefix = ""
    var unwrapResponse = false
    var session = ProviderHTTP.session()

    func transcribe(meeting: Meeting, directory: URL, token: String) async throws -> Transcript {
        defer { session.finishTasksAndInvalidate() }
        let wave: URL
        do {
            wave = try AudioAssembler.makeUploadFile(for: meeting, in: directory)
        } catch {
            throw TranscriptionError.audioFile(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: wave) }
        let boundary = "BadMeeting-\(UUID().uuidString)"
        let body: URL
        do {
            body = try makeBody(audio: wave, boundary: boundary)
        } catch {
            throw TranscriptionError.audioFile(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authorizationPrefix + token, forHTTPHeaderField: authorizationHeader)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: body)
        } catch {
            throw TranscriptionError.network(error.localizedDescription,
                                             retryable: TranscriptionError.isRetryableNetworkFailure(error))
        }
        guard let response = response as? HTTPURLResponse else { throw TranscriptionError.invalidHTTPResponse }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        guard (200...299).contains(response.statusCode) else {
            throw Self.responseFailure(TranscriptionError.server(response.statusCode), data: data,
                                       statusCode: response.statusCode, contentType: contentType, redactingToken: token)
        }
        do {
            return try Self.parseResponse(ProviderResponse.data(data, unwrap: unwrapResponse))
        } catch {
            throw Self.responseFailure(error, data: data, statusCode: response.statusCode,
                                       contentType: contentType, redactingToken: token)
        }
    }

    static func responseFailure(_ error: Error, data: Data, statusCode: Int,
                                contentType: String?, redactingToken: String? = nil) -> TranscriptionFailure {
        let limit = 256 * 1024
        let body = String(decoding: data.prefix(limit), as: UTF8.self)
        let suffix = data.count > limit ? "\n[Ответ обрезан до первых \(limit) байт.]" : ""
        let failure = TranscriptionFailure(
            message: error.localizedDescription,
            diagnosticDetails: """
            Запрос: POST /v1/speech-to-text
            Код HTTP: \(statusCode)
            Content-Type: \(contentType ?? "не указан")
            Размер ответа: \(data.count) байт
            Ошибка обработки: \(error.localizedDescription)

            Ответ сервиса:
            \(body)\(suffix)
            """
        )
        guard let token = redactingToken, !token.isEmpty else { return failure }
        return TranscriptionFailure(message: failure.message.replacingOccurrences(of: token, with: "[скрыто]"),
                                    diagnosticDetails: failure.diagnosticDetails.replacingOccurrences(of: token, with: "[скрыто]"))
    }

    static func parseResponse(_ data: Data) throws -> Transcript {
        guard !data.isEmpty else { throw TranscriptionError.emptyResponse }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranscriptionError.invalidJSON
        }
        guard let response = json as? [String: Any] else { throw TranscriptionError.invalidResponse }
        let transcriptResponse = response
        let text = transcriptResponse["text"] as? String
        var words: [TranscriptWord] = []
        var wordWarning: String?
        if let rawWords = transcriptResponse["words"], !(rawWords is NSNull) {
            if let rawWords = rawWords as? [Any] {
                do {
                    let wordData = try JSONSerialization.data(withJSONObject: rawWords)
                    words = try JSONDecoder().decode([TranscriptWord].self, from: wordData)
                } catch {
                    wordWarning = "Сервис вернул текст, но разметка слов недоступна: \(Self.wordError(error))"
                }
            } else {
                wordWarning = "Сервис вернул текст, но поле words не является списком слов."
            }
        } else {
            wordWarning = "Сервис вернул текст без поля words. Разметка спикеров недоступна."
        }
        let resolvedText = text ?? words.map(\.text).joined()
        guard !resolvedText.isEmpty || !words.isEmpty else { throw TranscriptionError.invalidResponse }
        if words.isEmpty && wordWarning == nil {
            wordWarning = "Сервис вернул пустой список слов. Разметка спикеров недоступна."
        }
        return Transcript(text: resolvedText, words: words, speakerNames: [:], wordWarning: wordWarning)
    }

    private static func wordError(_ error: Error) -> String {
        let path: [CodingKey]
        let issue: String
        switch error {
        case let DecodingError.keyNotFound(key, context):
            path = context.codingPath + [key]
            issue = "отсутствует поле"
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            path = context.codingPath
            issue = "поле имеет неверный тип или пустое значение"
        case let DecodingError.dataCorrupted(context):
            path = context.codingPath
            issue = "поле повреждено"
        default:
            return "список words имеет неверный формат."
        }
        let suffix = path.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return ".\(key.stringValue)"
        }.joined()
        return "\(issue) words\(suffix)."
    }

    private func makeBody(audio: URL, boundary: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-\(UUID().uuidString).multipart")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        for (name, value) in [
            ("model_id", "scribe_v2"),
            ("diarize", settings.diarize ? "true" : "false"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false")
        ].filter({ !$0.1.isEmpty }) + (settings.language.isEmpty ? [] : [("language_code", settings.language)]) {
            let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            try output.write(contentsOf: Data(part.utf8))
        }
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return url
    }
}
