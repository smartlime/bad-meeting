import CryptoKit
import Foundation

struct SpeechKitSettings: Codable, Equatable, Sendable {
    var folderID = ""
    var language = "ru-RU"
    var speakerLabeling = false
    var literatureText = true

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "BadMeeting.speechKitSettings"),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "BadMeeting.speechKitSettings") }
    }
}

struct SpeechKitFailure: LocalizedError {
    let message: String
    var retryable = false
    var errorDescription: String? { message }
}

private final class SpeechKitRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct SpeechKitTranscriber {
    let settings: SpeechKitSettings
    var session: URLSession = URLSession(configuration: .ephemeral, delegate: SpeechKitRedirectPolicy(), delegateQueue: nil)
    var pollDelay: Duration = .seconds(5)
    var chunkBytes = 20 * 60 * 32_000
    static let checkpointName = "speechkit-operation.json"

    struct Checkpoint: Codable {
        var fingerprint: String
        var createdAt: Date
        var operations: [String: String] = [:]

        func save(to url: URL) throws {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func clearCheckpoint(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(checkpointName))
    }

    func transcribe(meeting: Meeting, directory: URL, credentials: CredentialSettings,
                    progress: @escaping @Sendable (String) async -> Void) async throws -> Transcript {
        defer { session.finishTasksAndInvalidate() }
        let token = try await credentials.token(for: .speechkit)
        try validate(token: token)
        await progress("Подготавливается аудио для SpeechKit")
        let wave = try AudioAssembler.makeUploadFile(for: meeting, in: directory)
        defer { try? FileManager.default.removeItem(at: wave) }
        return try await transcribe(wave: wave, directory: directory, token: token, progress: progress)
    }

    func validate(token: String) throws {
        guard !settings.folderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.folderID.contains(where: { $0.isNewline }) else {
            throw SpeechKitFailure(message: "Не задан корректный каталог Yandex Cloud. Проверь настройки SpeechKit.")
        }
        guard !token.isEmpty, !token.contains(where: { $0.isNewline }) else {
            throw SpeechKitFailure(message: "Не задан корректный ключ SpeechKit.")
        }
    }

    func transcribe(wave: URL, directory: URL, token: String,
                    progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> Transcript {
        try validate(token: token)
        let file = try FileHandle(forReadingFrom: wave)
        defer { try? file.close() }
        let header = try file.read(upToCount: 44) ?? Data()
        guard header.count == 44, String(decoding: header.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: header[36..<40], as: UTF8.self) == "data" else {
            throw SpeechKitFailure(message: "Не удалось подготовить аудио SpeechKit.")
        }
        let size = Int(try file.seekToEnd()) - 44
        guard chunkBytes <= 20 * 60 * 32_000 else {
            throw SpeechKitFailure(message: "Размер части превышает лимит прямой загрузки SpeechKit.")
        }
        guard size > 0, size % 2 == 0, chunkBytes > 0, chunkBytes % 2 == 0 else {
            throw SpeechKitFailure(message: "Запись не содержит корректного аудио для SpeechKit.")
        }
        let count = (size + chunkBytes - 1) / chunkBytes
        var hash = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        hash.update(data: try encoder.encode(settings))
        hash.update(data: Data(String(chunkBytes).utf8))
        try file.seek(toOffset: 0)
        while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let checkpointURL = directory.appendingPathComponent(Self.checkpointName)
        var checkpoint = Checkpoint(fingerprint: fingerprint, createdAt: Date())
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            let previous = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
            if previous.fingerprint == fingerprint, Date().timeIntervalSince(previous.createdAt) < 3 * 24 * 3600 {
                checkpoint = previous
            }
        }
        var phrases: [TranscriptWord] = []
        var texts: [String] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let key = String(index)
            await progress("SpeechKit: обрабатывается часть \(index + 1) из \(count)")
            let operationID: String
            if let existing = checkpoint.operations[key] {
                operationID = existing
            } else {
                try file.seek(toOffset: UInt64(44 + index * chunkBytes))
                let audio = try file.read(upToCount: min(chunkBytes, size - index * chunkBytes)) ?? Data()
                let body = try requestBody(audio: audio)
                var request = authorized(URL(string: "https://stt.api.cloud.yandex.net/stt/v3/recognizeFileAsync")!, token: token)
                request.httpMethod = "POST"
                request.httpBody = body
                let response: Data
                do { response = try await send(request) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    throw SpeechKitFailure(message: "Не удалось отправить часть \(index + 1) в SpeechKit. Статус приёма может быть неизвестен; автоматическая повторная отправка отключена. \(error.localizedDescription)")
                }
                let object = try json(response)
                guard let id = object["id"] as? String, !id.isEmpty else {
                    throw SpeechKitFailure(message: "SpeechKit не вернул идентификатор операции. Автоматическая повторная отправка отключена.")
                }
                operationID = id
                checkpoint.operations[key] = id
                try checkpoint.save(to: checkpointURL)
            }
            let deadline = Date().addingTimeInterval(24 * 3600)
            while true {
                try Task.checkCancellation()
                let url = URL(string: "https://operation.api.cloud.yandex.net/operations/")!.appendingPathComponent(operationID)
                let status = try json(await read(authorized(url, token: token)))
                if let error = status["error"] as? [String: Any] {
                    checkpoint.operations[key] = nil
                    try checkpoint.save(to: checkpointURL)
                    throw SpeechKitFailure(message: "SpeechKit завершил операцию с ошибкой (код \(error["code"] ?? "не указан")).")
                }
                if status["done"] as? Bool == true { break }
                guard Date() < deadline else {
                    throw SpeechKitFailure(message: "SpeechKit ещё не завершил обработку. Повторный запуск продолжит ожидание сохранённой операции.")
                }
                try await Task.sleep(for: pollDelay)
            }
            var components = URLComponents(string: "https://stt.api.cloud.yandex.net/stt/v3/getRecognition")!
            components.queryItems = [URLQueryItem(name: "operation_id", value: operationID)]
            let data = try await read(authorized(components.url!, token: token))
            let result = try Self.parseResponse(data, offset: Double(index * chunkBytes) / 32_000,
                                                speakerPrefix: count > 1 ? "часть_\(index + 1)_" : "",
                                                speakerLabeling: settings.speakerLabeling)
            phrases += result.words
            if !result.text.isEmpty { texts.append(result.text) }
        }
        guard !phrases.isEmpty || !texts.isEmpty else {
            throw SpeechKitFailure(message: "SpeechKit не обнаружил речь в записи.")
        }
        let warning = count > 1 && settings.speakerLabeling
            ? "Дикторы определены отдельно для каждой части записи. Одинаковый номер в разных частях не означает одного человека." : nil
        return Transcript(text: texts.joined(separator: "\n"), words: phrases, speakerNames: [:],
                          wordWarning: warning, transcriptionProvider: TranscriptionModel.speechkit.rawValue)
    }

    func requestBody(audio: Data) throws -> Data {
        var recognition: [String: Any] = [
            "model": "general",
            "audioFormat": ["rawAudio": ["audioEncoding": "LINEAR16_PCM", "sampleRateHertz": "16000", "audioChannelCount": "1"]],
            "textNormalization": ["textNormalization": "TEXT_NORMALIZATION_ENABLED", "literatureText": settings.literatureText, "profanityFilter": false]
        ]
        if !settings.language.isEmpty {
            recognition["languageRestriction"] = ["restrictionType": "WHITELIST", "languageCode": [settings.language]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "content": audio.base64EncodedString(), "recognitionModel": recognition,
            "speakerLabeling": ["speakerLabeling": settings.speakerLabeling ? "SPEAKER_LABELING_ENABLED" : "SPEAKER_LABELING_DISABLED"]
        ])
    }

    func authorized(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Api-Key \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.folderID.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-folder-id")
        request.setValue("false", forHTTPHeaderField: "x-data-logging-enabled")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw SpeechKitFailure(message: "Не удалось получить ответ SpeechKit из-за сетевой ошибки.",
                                   retryable: TranscriptionError.isRetryableNetworkFailure(error))
        }
        guard let response = response as? HTTPURLResponse else {
            throw SpeechKitFailure(message: "SpeechKit не вернул код ответа.")
        }
        guard (200...299).contains(response.statusCode) else {
            throw SpeechKitFailure(message: "SpeechKit вернул ошибку HTTP \(response.statusCode).", retryable: response.statusCode == 429 || response.statusCode >= 500)
        }
        return data
    }

    private func read(_ request: URLRequest) async throws -> Data {
        // Only reads are retried: repeating a POST could create another paid operation.
        for attempt in 0..<3 {
            do { return try await send(request) }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard attempt < 2, (error as? SpeechKitFailure)?.retryable == true else { throw error }
                try await Task.sleep(for: pollDelay)
            }
        }
        throw SpeechKitFailure(message: "Не удалось прочитать результат SpeechKit.")
    }

    private func json(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpeechKitFailure(message: "SpeechKit вернул некорректный ответ.")
        }
        return object
    }

    static func parseResponse(_ data: Data, offset: Double = 0, speakerPrefix: String = "", speakerLabeling: Bool = false) throws -> Transcript {
        var records: [[String: Any]] = []
        var depth = 0
        var quoted = false
        var escaped = false
        var start = 0
        let bytes = Array(data)
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            else if byte == 123 {
                if depth == 0 { start = index }
                depth += 1
            } else if byte == 125 {
                depth -= 1
                guard depth >= 0 else { throw SpeechKitFailure(message: "SpeechKit вернул повреждённый результат.") }
                if depth == 0 {
                    guard let record = try? JSONSerialization.jsonObject(with: Data(bytes[start...index])) as? [String: Any] else {
                        throw SpeechKitFailure(message: "SpeechKit вернул повреждённый результат.")
                    }
                    records.append(record)
                }
            } else if depth == 0 && ![9, 10, 13, 32].contains(byte) {
                throw SpeechKitFailure(message: "SpeechKit вернул повреждённый результат.")
            }
        }
        guard depth == 0, !quoted, !records.isEmpty else { throw SpeechKitFailure(message: "SpeechKit вернул неполный результат.") }
        var phrases: [String: (Int, TranscriptWord)] = [:]
        var knownResult = false
        func number(_ value: Any?) -> Double? {
            if let value = value as? String { return Double(value) }
            return (value as? NSNumber)?.doubleValue
        }
        for (order, record) in records.enumerated() {
            if record["error"] != nil { throw SpeechKitFailure(message: "SpeechKit вернул ошибку получения результата.") }
            let result = record["result"] as? [String: Any] ?? record
            let refinement = result["finalRefinement"] as? [String: Any]
            let update = refinement?["normalizedText"] as? [String: Any] ?? result["final"] as? [String: Any]
            guard let update else {
                if result["sessionUuid"] != nil || result["statusCode"] != nil { knownResult = true }
                continue
            }
            knownResult = true
            guard let alternative = (update["alternatives"] as? [[String: Any]])?.first else { continue }
            let rawWords = alternative["words"] as? [[String: Any]] ?? []
            let text = (alternative["text"] as? String ?? rawWords.compactMap { $0["text"] as? String }.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            guard let begin = number(alternative["startTimeMs"]) ?? number(rawWords.first?["startTimeMs"]),
                  let end = number(alternative["endTimeMs"]) ?? number(rawWords.last?["endTimeMs"]),
                  begin.isFinite, end.isFinite, begin >= 0, end >= begin else {
                throw SpeechKitFailure(message: "SpeechKit вернул текст без корректных временных меток.")
            }
            let channel = String(describing: update["channelTag"] ?? result["channelTag"] ?? "0")
            let cursor = result["audioCursors"] as? [String: Any]
            let finalIndex = String(describing: refinement?["finalIndex"] ?? cursor?["finalIndex"] ?? "\(order)")
            let key = "\(channel):\(finalIndex)"
            let speaker = speakerLabeling ? "\(speakerPrefix)диктор_\(channel)" : "unknown"
            let word = TranscriptWord(start: offset + begin / 1000, end: offset + end / 1000,
                                      text: text + " ", type: "word", speakerID: speaker)
            if refinement != nil || phrases[key] == nil { phrases[key] = (phrases[key]?.0 ?? order, word) }
        }
        guard knownResult else { throw SpeechKitFailure(message: "Ответ SpeechKit не содержит результатов распознавания.") }
        let words = phrases.values.sorted { $0.1.start == $1.1.start ? $0.0 < $1.0 : $0.1.start < $1.1.start }.map { $0.1 }
        return Transcript(text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines), words: words,
                          speakerNames: [:], transcriptionProvider: TranscriptionModel.speechkit.rawValue)
    }
}
