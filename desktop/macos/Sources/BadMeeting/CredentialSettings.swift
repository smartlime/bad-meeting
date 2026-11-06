import Foundation
import Security

struct CredentialService: Hashable, Sendable {
    let rawValue: String
    let environmentKey: String
    var legacyDefaultsKey: String? = nil
    var keychainService = "BadMeeting.Credentials"
    var keychainAccount: String? = nil

    static let speechkit = Self(rawValue: "speechkit", environmentKey: "YC_AI_STUDIO_KEY", keychainService: "BadMeeting.SpeechKit", keychainAccount: "YC_API_KEY")
    static let elevenLabs = Self(rawValue: "elevenlabs", environmentKey: "ELEVENLABS_API_KEY")
    static let aiStudio = Self(rawValue: "ai_studio", environmentKey: "YC_AI_STUDIO_KEY")
    static let openRouter = Self(rawValue: "openrouter", environmentKey: "OPENROUTER_API_KEY")
}

struct CredentialSettings: Sendable {
    var useAIW = false
    var legacyTokens: [String: String] = [:]
    var aiwNames: [String: String] = [:]

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(useAIW: defaults.object(forKey: "BadMeeting.useAIW") as? Bool ?? false,
             legacyTokens: Dictionary(uniqueKeysWithValues: Edition.credentialServices.compactMap { service in
                 guard let key = service.legacyDefaultsKey, let value = defaults.string(forKey: key) else { return nil }
                 return (service.rawValue, value)
             }), aiwNames: defaults.dictionary(forKey: "BadMeeting.aiwNames") as? [String: String] ?? [:])
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(useAIW, forKey: "BadMeeting.useAIW")
        defaults.set(aiwNames, forKey: "BadMeeting.aiwNames")
    }

    func keyName(for service: CredentialService) -> String {
        aiwNames[service.rawValue] ?? service.environmentKey
    }

    static func masked(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        guard value.count > 8 else { return "***" }
        return String(value.prefix(3)) + "..." + String(value.suffix(3))
    }

    func legacyToken(for service: CredentialService) -> String { legacyTokens[service.rawValue] ?? "" }

    mutating func clearLegacy(_ service: CredentialService, from defaults: UserDefaults) {
        legacyTokens[service.rawValue] = nil
        if let key = service.legacyDefaultsKey { defaults.removeObject(forKey: key) }
    }

    func token(for service: CredentialService,
               environment: [String: String] = ProcessInfo.processInfo.environment,
               managedValue: @Sendable (String) async throws -> String = { try await Self.aiwValue($0) },
               storedValue: @Sendable (CredentialService) async throws -> String = { service in
                   try await Task.detached { try CredentialKeychain.read(service) }.value
               }) async throws -> String {
        let value: String
        if useAIW {
            if let inherited = environment[keyName(for: service)], !inherited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value = inherited
            } else {
                value = try await managedValue(keyName(for: service))
            }
        } else {
            let legacy = legacyToken(for: service)
            value = legacy.isEmpty ? try await storedValue(service) : legacy
        }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isNewline }) else {
            throw CredentialFailure(message: "Не задан токен \(service.environmentKey). Проверь настройки авторизации.")
        }
        return token
    }

    private static let aiwQueue = DispatchQueue(label: "BadMeeting.aiw-credentials", qos: .utility)

    static func aiwValue(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> String {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw CredentialFailure(message: "Некорректное имя ключа aiw.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            aiwQueue.async {
                do { continuation.resume(returning: try readAIWValue(name, environment: environment)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func readAIWValue(_ name: String, environment: [String: String]) throws -> String {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/aiw" } + ["/opt/homebrew/bin/aiw"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CredentialFailure(message: "Не удалось найти aiw.")
        }
        for attempt in 0..<5 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = ["value", name]
            task.environment = environment
            let output = Pipe()
            let errors = Pipe()
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = output
            task.standardError = errors
            do { try task.run() }
            catch { throw CredentialFailure(message: "Не удалось запустить aiw.") }
            let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            timeout.cancel()
            if task.terminationStatus == 0 { return String(decoding: data, as: UTF8.self) }
            let errorText = String(decoding: errorData, as: UTF8.self)
            if errorText.contains("Keychain vault is busy") {
                guard attempt < 4 else { break }
                Thread.sleep(forTimeInterval: 0.1 * pow(2, Double(attempt)))
                continue
            }
            if errorText.contains("Keychain access unavailable") {
                throw CredentialFailure(message: "Хранилище aiw недоступно. Требуется разблокировка через aiw unlock.")
            }
            throw CredentialFailure(message: "aiw завершился с ошибкой (код \(task.terminationStatus)) при чтении ключа \(name).")
        }
        throw CredentialFailure(message: "Хранилище aiw занято другим процессом.")
    }
}

struct CredentialFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}


enum CredentialKeychain {
    private static func query(_ service: CredentialService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service.keychainService,
         kSecAttrAccount as String: service.keychainAccount ?? service.rawValue]
    }

    static func read(_ service: CredentialService) throws -> String {
        var request = query(service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialFailure(message: "Не удалось прочитать ключ из Связки ключей (\(status)).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, for service: CredentialService) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isNewline }) else {
            throw CredentialFailure(message: "Ключ не должен быть пустым или содержать переносы строк.")
        }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let query = query(service)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CredentialFailure(message: "Не удалось сохранить ключ в Связке ключей (\(status)).")
        }
    }

    static func delete(_ service: CredentialService) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialFailure(message: "Не удалось удалить ключ из Связки ключей (\(status)).")
        }
    }
}

enum SpeechKitKeychain {
    static func read() throws -> String { try CredentialKeychain.read(.speechkit) }
    static func save(_ value: String) throws { try CredentialKeychain.save(value, for: .speechkit) }
}
