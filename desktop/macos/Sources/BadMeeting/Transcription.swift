import Foundation

enum TranscriptionError: LocalizedError {
    case missingToken
    case emptyResponse
    case invalidJSON
    case invalidResponse
    case invalidHTTPResponse
    case audioFile(String)
    case network(String, retryable: Bool)
    case saveTranscript(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .missingToken: "Не задан ключ сервиса. Проверь настройки авторизации."
        case .emptyResponse: "Сервис вернул пустой ответ вместо расшифровки."
        case .invalidJSON: "Сервис вернул ответ, который не является JSON-документом с расшифровкой."
        case .invalidResponse: "Ответ сервиса не содержит ни текста, ни списка слов."
        case .invalidHTTPResponse: "Сервис не вернул код HTTP-ответа."
        case let .audioFile(detail): "Не удалось подготовить WAV-файл записи для распознавания: \(detail)"
        case let .network(detail, _): "Не удалось получить ответ сервиса: \(detail)"
        case let .saveTranscript(detail): "Не удалось сохранить расшифровку записи на Mac: \(detail)"
        case let .server(code): "Сервис вернул ошибку HTTP \(code)."
        }
    }

    static func isRetryableNetworkFailure(_ error: Error) -> Bool {
        if let transcriptionError = error as? Self {
            if case let .network(_, retryable) = transcriptionError { return retryable }
            return false
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .timedOut:
            return true
        default:
            return false
        }
    }
}

struct TranscriptionRetryFailure: LocalizedError, ErrorDiagnosticsProviding {
    let attempts: Int
    let underlyingError: Error

    var errorDescription: String? {
        "Не удалось расшифровать запись после \(attempts) попыток из-за ошибки соединения."
    }

    var diagnosticDetails: String {
        """
        Операция: Расшифровка записи
        Попыток: \(attempts)
        Последняя ошибка: \(underlyingError.localizedDescription)
        """
    }
}

struct TranscriptionFailure: LocalizedError, ErrorDiagnosticsProviding {
    let message: String
    let diagnosticDetails: String

    var errorDescription: String? { message }
}
