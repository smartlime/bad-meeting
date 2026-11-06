import Foundation

struct CalendarPerson: Codable, Identifiable, Hashable {
    var name: String
    var email: String
    var decision: String
    var id: String { email.isEmpty ? name : email }
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? email : trimmedName
    }
    var responseLabel: String {
        switch decision {
        case "yes", "accepted": return "Принято"
        case "no", "declined": return "Отклонено"
        case "maybe", "tentative": return "Под вопросом"
        default: return "Нет ответа"
        }
    }
    var responseSymbol: String {
        switch decision {
        case "yes", "accepted": return "checkmark.circle.fill"
        case "no", "declined": return "xmark.circle"
        case "maybe", "tentative": return "clock"
        default: return "questionmark.circle"
        }
    }
}

struct CalendarEvent: Codable, Identifiable, Hashable {
    var remoteID: String
    var instanceStart: Date
    var start: Date
    var end: Date
    var title: String
    var description: String = ""
    var timezone: String = "Europe/Moscow"
    var organizer: CalendarPerson?
    var attendees: [CalendarPerson] = []
    var room: String = ""
    var videoURLs: [URL] = []
    var callPasswords: [String: String]? = nil
    var calendarURL: URL?
    var layerID: String = ""
    var allDay: Bool = false
    var cancelled: Bool = false
    var decision: String = ""
    var detailsLoaded: Bool = false
    var occurrenceID: String? = nil
    var sourceID: String? = nil
    var id: String { remoteID + (occurrenceID.map { "@" + $0 } ?? "") }
    var calls: [CalendarCall] {
        CalendarParser.calls(description: description, urls: videoURLs).map { call in
            var result = call
            result.password = callPasswords?[call.url.absoluteString] ?? call.password
            return result
        }
    }
    var speakerCandidates: [CalendarPerson] {
        var people: [CalendarPerson] = []
        for person in (organizer.map { [$0] } ?? []) + attendees {
            guard !person.displayName.isEmpty else { continue }
            let duplicate = people.contains {
                if !$0.email.isEmpty && !person.email.isEmpty { return $0.email.lowercased() == person.email.lowercased() }
                return $0.displayName.localizedCaseInsensitiveCompare(person.displayName) == .orderedSame
            }
            if !duplicate { people.append(person) }
        }
        return people
    }
    var shouldRemind: Bool { !allDay && !cancelled && !["no", "declined"].contains(decision) }
    var timeText: String {
        if allDay { return "Весь день" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timezone)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: start) + " – " + formatter.string(from: end)
    }
    func overlaps(_ other: CalendarEvent) -> Bool { id != other.id && start < other.end && other.start < end }
    static func videoProvider(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com") { return "Zoom" }
        if host == "telemost.360.yandex.ru" || host == "telemost.yandex.ru" || host == "telemost.yandex.com" { return "Телемост" }
        if host == "t.me" || host == "telegram.me" || host == "telegram.org" { return "Telegram" }
        return Edition.additionalVideoProvider(url)
    }
}

struct CalendarCall: Identifiable, Hashable {
    var url: URL
    var password: String?
    var id: String { url.absoluteString }
    var label: String {
        guard let provider = CalendarEvent.videoProvider(url) else { return url.absoluteString }
        let parts = url.pathComponents.filter { $0 != "/" }
        if let marker = parts.firstIndex(where: { ["j", "join"].contains($0) }), parts.indices.contains(marker + 1) {
            return provider + ": " + parts[marker + 1]
        }
        return url.absoluteString
    }
}

struct CalendarLayer: Codable, Identifiable {
    let id: String
    let name: String
    var sourceID: String? = nil
}

struct CalendarSettings: Codable, Equatable {
    var connected = Edition.defaultCalendarConnected
    var additionalSources: [String: CalendarConnectionSettings] = [:]
    var layerIDs: [String]? = nil
    var timezone = TimeZone.current.identifier
    var historyDays = 14
    var snoozeMinutes = 3
    var remindSoon = true
    var soonMinutes = 6
    var remindStart = true
    var remindEnd = true
    var fullscreenSoon = false
    var fullscreenStart = false
    var fullscreenEnd = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case connected, additionalSources, layerIDs, timezone, historyDays, snoozeMinutes, remindSoon, soonMinutes
        case remindStart, remindEnd, fullscreenSoon, fullscreenStart, fullscreenEnd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? Edition.defaultCalendarConnected
        additionalSources = try c.decodeIfPresent([String: CalendarConnectionSettings].self, forKey: .additionalSources) ?? [:]
        layerIDs = try c.decodeIfPresent([String].self, forKey: .layerIDs)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? TimeZone.current.identifier
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? 14
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 3
        remindSoon = try c.decodeIfPresent(Bool.self, forKey: .remindSoon) ?? true
        soonMinutes = try c.decodeIfPresent(Int.self, forKey: .soonMinutes) ?? 6
        remindStart = try c.decodeIfPresent(Bool.self, forKey: .remindStart) ?? true
        remindEnd = try c.decodeIfPresent(Bool.self, forKey: .remindEnd) ?? true
        fullscreenStart = try c.decodeIfPresent(Bool.self, forKey: .fullscreenStart) ?? false
        fullscreenEnd = try c.decodeIfPresent(Bool.self, forKey: .fullscreenEnd) ?? false
        fullscreenSoon = try c.decodeIfPresent(Bool.self, forKey: .fullscreenSoon) ?? fullscreenStart
    }

    func connection(_ source: CalendarSource) -> CalendarConnectionSettings {
        if source.id == Edition.calendarSources[0].id { return CalendarConnectionSettings(enabled: connected, layerIDs: layerIDs) }
        return additionalSources[source.id] ?? CalendarConnectionSettings(enabled: false, layerIDs: source.defaultSelection)
    }
    mutating func setConnection(_ value: CalendarConnectionSettings, for source: CalendarSource) {
        if source.id == Edition.calendarSources[0].id { connected = value.enabled; layerIDs = value.layerIDs }
        else { additionalSources[source.id] = value }
    }
    var anyCalendarEnabled: Bool { Edition.calendarSources.contains { connection($0).enabled } }
    func includes(_ event: CalendarEvent) -> Bool {
        guard let source = Edition.calendarSources.first(where: { $0.id == (event.sourceID ?? Edition.calendarSources[0].id) }) else { return false }
        let value = connection(source)
        return value.enabled && (value.layerIDs?.contains(event.layerID) ?? true)
    }

    func fullscreen(for phase: ReminderPhase) -> Bool {
        switch phase {
        case .soon: fullscreenSoon
        case .start: fullscreenStart
        case .end: fullscreenEnd
        }
    }
}

struct CalendarCache: Codable {
    var events: [CalendarEvent] = []
    var layers: [CalendarLayer] = []
    var lastSync: Date?
    var settings = CalendarSettings()
    var reminders: [String: ReminderDisposition] = [:]

    mutating func prune(now: Date, recordings: [Meeting]) {
        let lower = now.addingTimeInterval(-Double(settings.historyDays) * 86400)
        let upper = now.addingTimeInterval(31 * 86400)
        let linked = Set(recordings.compactMap { $0.calendarEvent?.id })
        events.removeAll { ($0.end < lower || $0.start > upper) && !linked.contains($0.id) }
        let live = Set(events.map(\.id))
        reminders = reminders.filter { key, _ in live.contains(where: { key.hasPrefix($0 + "|") }) }
    }
}

struct SourceChange: Codable {
    let at: Date
    let name: String
}

struct ReminderDisposition: Codable {
    var dismissed = false
    var snoozedUntil: Date?
}

enum ReminderPhase: String, Codable { case soon, start, end }
struct MeetingReminder: Identifiable {
    let event: CalendarEvent
    let phase: ReminderPhase
    var recordingID: UUID? = nil
    var leadMinutes = 0
    var id: String {
        let base = event.id + "|" + phase.rawValue + "|" + String(Int((phase == .end ? event.end : event.start).timeIntervalSince1970))
        return phase == .end ? base + (recordingID.map { "|" + $0.uuidString } ?? "") : base
    }
}

enum ReminderPolicy {
    static func candidates(events: [CalendarEvent], active: CalendarEvent?, settings: CalendarSettings, recordingID: UUID? = nil, recordingStartedAt: Date? = nil) -> [MeetingReminder] {
        let eligible = events.filter(\.shouldRemind)
        var result = settings.remindSoon ? eligible.map { MeetingReminder(event: $0, phase: .soon, leadMinutes: settings.soonMinutes) } : []
        if settings.remindStart { result += eligible.map { MeetingReminder(event: $0, phase: .start) } }
        if settings.remindEnd, let active, !active.cancelled, !active.allDay,
           recordingStartedAt.map({ $0 < active.end }) ?? true {
            result.append(MeetingReminder(event: active, phase: .end, recordingID: recordingID))
        }
        return result
    }
    static func dueDate(_ reminder: MeetingReminder, states: [String: ReminderDisposition], now: Date) -> Date? {
        let state = states[reminder.id]
        if state?.dismissed == true { return nil }
        switch reminder.phase {
        case .soon:
            guard reminder.event.start > now else { return nil }
            let planned = reminder.event.start.addingTimeInterval(-Double(max(1, reminder.leadMinutes)) * 60)
            return max(planned, state?.snoozedUntil ?? .distantPast)
        case .start:
            guard reminder.event.end > now else { return nil }
            return max(reminder.event.start, state?.snoozedUntil ?? .distantPast)
        case .end:
            return max(reminder.event.end, state?.snoozedUntil ?? .distantPast)
        }
    }
}

struct CalendarFailure: LocalizedError, ErrorDiagnosticsProviding {
    let message: String
    var details: String = ""
    var errorDescription: String? { message }
    var diagnosticDetails: String { details.isEmpty ? message : details }
}

enum CalendarParser {
    static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    static func date(_ value: Any?, timezone: String) -> Date? {
        guard let text = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezone)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
    static func person(_ object: [String: Any]) -> CalendarPerson {
        let email = string(object["email"])
        let name = string(object["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarPerson(name: name.isEmpty ? email : name, email: email, decision: string(object["decision"]))
    }
    static func links(_ text: String) -> [NSTextCheckingResult] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter {
            ["https", "http", "mailto"].contains($0.url?.scheme?.lowercased() ?? "")
        }
    }

    static func calls(description: String, urls: [URL]) -> [CalendarCall] {
        var calls: [CalendarCall] = []
        let markers = ["Основная трансляция:", "Смотрите трансляцию в браузере", "Смотреть трансляцию в VCONF:"]
        for marker in markers {
            var remaining = description.startIndex..<description.endIndex
            while let range = description.range(of: marker, range: remaining) {
                let tail = String(description[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let line = tail.components(separatedBy: .newlines).first ?? ""
                let markdown = try? NSRegularExpression(pattern: #"^\[[^\]]*\]\((https?://[^\s)]+)\)"#)
                let match = markdown?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
                let markdownURL = match.flatMap { Range($0.range(at: 1), in: line) }.flatMap { URL(string: String(line[$0])) }
                let directURL = links(line).first.flatMap { $0.range.location == 0 ? $0.url : nil }
                if let url = markdownURL ?? directURL, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                   !calls.contains(where: { $0.url == url }) {
                    calls.append(CalendarCall(url: url))
                }
                remaining = range.upperBound..<description.endIndex
            }
        }
        var pending: [URL] = []
        for line in description.components(separatedBy: .newlines) {
            let labeled = line.range(of: "Ссылка на звонок:", options: .caseInsensitive) != nil
            let found = links(line).compactMap(\.url).filter { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && (labeled || CalendarEvent.videoProvider($0) != nil) }
            if !found.isEmpty {
                pending = found
                for url in found where !calls.contains(where: { $0.url == url }) {
                    calls.append(CalendarCall(url: url))
                }
            }
            if let range = line.range(of: "Пароль:", options: .caseInsensitive) {
                let password = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !password.isEmpty {
                    for url in pending {
                        if let index = calls.firstIndex(where: { $0.url == url }) { calls[index].password = password }
                    }
                }
                pending = []
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty && found.isEmpty {
                pending = []
            }
        }
        for url in urls where !calls.contains(where: { $0.url == url }) {
            calls.append(CalendarCall(url: url))
        }
        return calls
    }

}
