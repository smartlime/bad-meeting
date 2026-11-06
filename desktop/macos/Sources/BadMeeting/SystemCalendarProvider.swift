import EventKit
import Foundation

struct CalendarSource: Identifiable {
    let id: String
    let title: String
    var credential: CredentialService? = nil
    var defaultSelection: [String]? = nil
    let makeProvider: () -> any CalendarProviding
    static let system = Self(id: "system", title: "Системные календари", makeProvider: { SystemCalendarProvider() })
}

struct CalendarConnectionSettings: Codable, Equatable {
    var enabled = false
    var layerIDs: [String]? = nil
}

final class CombinedCalendarProvider: CalendarProviding {
    private let providers: [(CalendarSource, any CalendarProviding)]
    init(sources: [CalendarSource] = Edition.calendarSources) { providers = sources.map { ($0, $0.makeProvider()) } }

    func layers(timezone: String, settings: CalendarSettings) async throws -> [CalendarLayer] {
        var result: [CalendarLayer] = []
        for (source, provider) in providers where settings.connection(source).enabled {
            result += try await provider.layers(timezone: timezone, settings: settings).map {
                CalendarLayer(id: $0.id, name: $0.name, sourceID: source.id)
            }
        }
        return result
    }

    func events(from: Date, to: Date, settings: CalendarSettings) async throws -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        for (source, provider) in providers {
            let connection = settings.connection(source)
            guard connection.enabled, connection.layerIDs?.isEmpty != true else { continue }
            var scoped = settings
            scoped.layerIDs = connection.layerIDs
            result += try await provider.events(from: from, to: to, settings: scoped).map {
                var event = $0
                event.sourceID = source.id
                return event
            }
        }
        return result
    }

    func detail(_ event: CalendarEvent, timezone: String) async throws -> CalendarEvent {
        guard let (source, provider) = providers.first(where: { $0.0.id == (event.sourceID ?? providers.first?.0.id) }) else { return event }
        var result = try await provider.detail(event, timezone: timezone)
        result.sourceID = source.id
        return result
    }
}

actor SystemCalendarProvider: CalendarProviding {
    private let store = EKEventStore()

    private func authorize() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return }
        if status == .notDetermined, try await store.requestFullAccessToEvents() { return }
        throw CalendarFailure(message: "Нет доступа к системным календарям. Разрешение задается в настройках конфиденциальности macOS.")
    }

    func layers(timezone: String, settings: CalendarSettings) async throws -> [CalendarLayer] {
        try await authorize()
        return store.calendars(for: .event).map { CalendarLayer(id: $0.calendarIdentifier, name: $0.title, sourceID: "system") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func events(from: Date, to: Date, settings: CalendarSettings) async throws -> [CalendarEvent] {
        try await authorize()
        let calendars = store.calendars(for: .event).filter { settings.layerIDs?.contains($0.calendarIdentifier) ?? true }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map(Self.convert)
    }

    func detail(_ event: CalendarEvent, timezone: String) async throws -> CalendarEvent { event }

    static func convert(_ event: EKEvent) -> CalendarEvent {
        let start = event.startDate ?? Date.distantPast
        let description = event.notes ?? ""
        let directURL = event.url.flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let urls = CalendarParser.links(description).compactMap(\.url).filter { CalendarEvent.videoProvider($0) != nil } + (directURL.map { [$0] } ?? [])
        return CalendarEvent(remoteID: "system:" + event.calendar.calendarIdentifier + ":" + event.calendarItemIdentifier,
            instanceStart: event.occurrenceDate ?? start, start: start, end: event.endDate ?? start,
            title: event.title ?? "", description: description, timezone: event.timeZone?.identifier ?? TimeZone.current.identifier,
            organizer: event.organizer.map(person), attendees: event.attendees?.map(person) ?? [], room: event.location ?? "",
            videoURLs: Array(Set(urls)), layerID: event.calendar.calendarIdentifier,
            allDay: event.isAllDay, cancelled: event.status == .canceled,
            decision: event.attendees?.first(where: \.isCurrentUser).map { decision($0.participantStatus) } ?? "",
            detailsLoaded: true, occurrenceID: String((event.occurrenceDate ?? start).timeIntervalSince1970), sourceID: "system")
    }

    private static func person(_ participant: EKParticipant) -> CalendarPerson {
        CalendarPerson(name: participant.name ?? "", email: participant.url.scheme == "mailto" ? (String(participant.url.absoluteString.dropFirst(7)).removingPercentEncoding ?? "") : "",
                       decision: decision(participant.participantStatus))
    }
    private static func decision(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        default: ""
        }
    }
}
