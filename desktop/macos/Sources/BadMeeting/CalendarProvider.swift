import Foundation

protocol CalendarProviding {
    func layers(timezone: String, settings: CalendarSettings) async throws -> [CalendarLayer]
    func events(from: Date, to: Date, settings: CalendarSettings) async throws -> [CalendarEvent]
    func detail(_ event: CalendarEvent, timezone: String) async throws -> CalendarEvent
}

@MainActor
final class CalendarModel: ObservableObject {
    @Published var cache = CalendarCache()
    @Published private(set) var syncing = false
    @Published private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var timer: Timer?
    private var detailTasks: [String: Task<CalendarEvent, Error>] = [:]
    private var pendingRefresh: (Date?, Bool)?
    private var refreshError: String?
    private let provider: any CalendarProviding
    private let file: URL
    var recordings: () -> [Meeting] = { [] }
    var settings: CalendarSettings { cache.settings }
    var displayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = TimeZone(identifier: settings.timezone) ?? .current
        return calendar
    }

    init(file: URL? = nil, provider: any CalendarProviding = CombinedCalendarProvider()) {
        self.provider = provider
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BadMeeting/calendar.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do { cache = try JSONDecoder().decode(CalendarCache.self, from: Data(contentsOf: self.file)) }
            catch { errorMessage = "Не удалось прочитать сохранённое расписание календаря: \(error.localizedDescription)" }
        }
    }

    func start() {
        guard settings.anyCalendarEnabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 15
        Task { await refresh() }
    }

    func updateSettings(_ edit: (inout CalendarSettings) -> Void) {
        let previous = settings
        edit(&cache.settings)
        if !settings.anyCalendarEnabled { refreshError = nil; errorMessage = nil }
        cache.events.removeAll { !settings.includes($0) }
        prune()
        persist()
        onChange?()
        if previous.connected != settings.connected || previous.layerIDs != settings.layerIDs || previous.additionalSources != settings.additionalSources || previous.timezone != settings.timezone || previous.historyDays != settings.historyDays {
            timer?.invalidate()
            timer = nil
            cache.layers = []
            start()
        }
    }

    func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: file, options: .atomic)
        } catch { onError?(CalendarFailure(message: "Не удалось сохранить календарь и настройки напоминаний.", details: error.localizedDescription)) }
    }

    func refresh(day: Date? = nil, userInitiated: Bool = false) async {
        guard settings.anyCalendarEnabled else { return }
        if syncing { pendingRefresh = (day, userInitiated); return }
        syncing = true
        defer {
            syncing = false
            if let pending = pendingRefresh {
                pendingRefresh = nil
                Task { await refresh(day: pending.0, userInitiated: pending.1) }
            }
        }
        let requestSettings = settings
        do {
            if cache.layers.isEmpty || userInitiated { cache.layers = try await provider.layers(timezone: settings.timezone, settings: requestSettings) }
            let today = displayCalendar.startOfDay(for: Date())
            let from = day.map { displayCalendar.startOfDay(for: $0) } ?? displayCalendar.date(byAdding: .day, value: -settings.historyDays, to: today)!
            let to = displayCalendar.date(byAdding: .day, value: day == nil ? 31 : 1, to: day == nil ? today : from)!
            let fetched = try await provider.events(from: from, to: to, settings: requestSettings)
            guard settings.anyCalendarEnabled, settings == requestSettings else { return }
            let old = Dictionary(uniqueKeysWithValues: cache.events.map { ($0.id, $0) })
            let fetchedIDs = Set(fetched.map(\.id))
            let linkedIDs = Set(recordings().compactMap { $0.calendarEvent?.id })
            let removedLinked = cache.events.filter { $0.start < to && $0.end >= from && linkedIDs.contains($0.id) && !fetchedIDs.contains($0.id) }
            cache.events.removeAll { fetchedIDs.contains($0.id) || ($0.start < to && $0.end >= from) }
            for var removed in removedLinked { removed.cancelled = true; cache.events.append(removed) }
            for var event in fetched {
                if let previous = old[event.id], previous.detailsLoaded,
                   previous.start == event.start, previous.end == event.end, previous.title == event.title,
                   previous.description == event.description {
                    event.attendees = previous.attendees
                    event.organizer = previous.organizer
                    event.room = event.room.isEmpty ? previous.room : event.room
                    event.videoURLs = Array(Set(event.videoURLs + previous.videoURLs)).sorted { $0.absoluteString < $1.absoluteString }
                    event.callPasswords = previous.callPasswords
                    event.calendarURL = event.calendarURL ?? previous.calendarURL
                }
                cache.events.append(event)
            }
            cache.events.sort { $0.start < $1.start }
            if day == nil { cache.lastSync = Date(); prune() }
            refreshError = nil
            errorMessage = nil
            persist()
            onChange?()
            let nearby = cache.events.filter { $0.shouldRemind && $0.end > Date() && $0.start < Date().addingTimeInterval(600) }
            for event in nearby { _ = await loadDetail(event) }
            onChange?()
        } catch {
            guard settings.anyCalendarEnabled, settings == requestSettings else { return }
            refreshError = error.localizedDescription
            errorMessage = refreshError
        }
    }

    func loadDetail(_ event: CalendarEvent) async -> CalendarEvent {
        guard settings.anyCalendarEnabled, !event.detailsLoaded else { return event }
        if let cached = cache.events.first(where: { $0.id == event.id && $0.detailsLoaded }) { return cached }
        if let pending = detailTasks[event.id] { return (try? await pending.value) ?? event }
        let requestTimezone = settings.timezone
        let requestSettings = settings
        let task = Task { try await provider.detail(event, timezone: requestTimezone) }
        detailTasks[event.id] = task
        defer { detailTasks.removeValue(forKey: event.id) }
        do {
            let detailed = try await task.value
            guard settings.anyCalendarEnabled, settings == requestSettings else { return event }
            if let index = cache.events.firstIndex(where: { $0.id == event.id }) { cache.events[index] = detailed }
            if refreshError == nil { errorMessage = nil }
            persist()
            return detailed
        } catch {
            guard settings.anyCalendarEnabled, settings == requestSettings else { return event }
            errorMessage = refreshError ?? error.localizedDescription
            return event
        }
    }

    func layers(for source: CalendarSource) -> [CalendarLayer] {
        cache.layers.filter { ($0.sourceID ?? Edition.calendarSources[0].id) == source.id }
    }

    func prune() { cache.prune(now: Date(), recordings: recordings()) }

    var visibleEvents: [CalendarEvent] {
        var unique: [String: CalendarEvent] = [:]
        for snapshot in recordings().compactMap(\.calendarEvent) { unique[snapshot.id] = snapshot }
        for event in cache.events where settings.includes(event) { unique[event.id] = event }
        return unique.values.filter { !$0.cancelled }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    func events(on date: Date) -> [CalendarEvent] {
        let start = displayCalendar.startOfDay(for: date)
        let end = displayCalendar.date(byAdding: .day, value: 1, to: start)!
        return visibleEvents.filter { $0.start < end && $0.end > start }
    }

    func adjacentDay(to date: Date, direction: Int) -> Date? {
        let calendar = displayCalendar
        let day = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: direction > 0 ? 1 : -1, to: day)!
        var candidates = recordings().map { calendar.startOfDay(for: $0.createdAt) }
        for event in visibleEvents {
            let first = calendar.startOfDay(for: event.start)
            let last = calendar.startOfDay(for: max(event.start, event.end.addingTimeInterval(-0.001)))
            let candidate = direction > 0 ? max(next, first) : min(next, last)
            if candidate >= first && candidate <= last { candidates.append(candidate) }
        }
        return direction > 0 ? candidates.filter { $0 > day }.min() : candidates.filter { $0 < day }.max()
    }
}
