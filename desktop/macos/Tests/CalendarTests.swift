@testable import BadMeetingKit
import Foundation

extension MeetingTests {
    static func calendarTests() throws {
        var oldSettings = CalendarSettings()
        oldSettings.fullscreenStart = true
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldSettings)) as! [String: Any]
        oldJSON.removeValue(forKey: "fullscreenSoon")
        var migrated = try JSONDecoder().decode(CalendarSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        precondition(migrated.fullscreen(for: .soon))
        migrated.fullscreenStart = false
        precondition(migrated.fullscreen(for: .soon) && !migrated.fullscreen(for: .start))
        migrated.fullscreenSoon = false
        migrated.fullscreenEnd = true
        let roundtrip = try JSONDecoder().decode(CalendarSettings.self, from: JSONEncoder().encode(migrated))
        precondition(!roundtrip.fullscreen(for: .soon) && roundtrip.fullscreen(for: .end))
        let start = Date(timeIntervalSince1970: 1790758800)
        func event(_ id: String, offset: Double = 0) -> CalendarEvent {
            CalendarEvent(remoteID: id, instanceStart: start.addingTimeInterval(offset), start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 1800), title: id, occurrenceID: id == "series" ? String(offset) : nil)
        }
        let first = event("series")
        let occurrence = event("series", offset: 86400)
        precondition(first.id != occurrence.id, "Recurring instances must not share links")
        let parallel = event("parallel")
        var rescheduled = parallel
        rescheduled.start = parallel.start.addingTimeInterval(3600)
        precondition(rescheduled.id == parallel.id, "Rescheduling a standalone event preserves its recording links")
        precondition(first.overlaps(parallel) && !first.overlaps(occurrence))
        let boundary = event("boundary", offset: 1800)
        precondition(!first.overlaps(boundary), "Adjacent meetings do not overlap")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var recording = Meeting(id: UUID(), createdAt: start, title: "Unscheduled", status: .ready, sourceName: "Microphone", segments: [], transcript: Transcript(text: "Saved", words: [], speakerNames: [:]), transcriptionError: nil)
        recording.calendarEvent = first
        recording.sourceChanges = [SourceChange(at: start, name: "Microphone")]
        try store.save(recording)
        let restored = try store.loadAll()[0]
        precondition(restored.calendarEvent == first && restored.sourceChanges?.count == 1)
        recording.calendarEvent = nil
        try store.save(recording)
        let unlinked = try store.loadAll()[0]
        precondition(unlinked.transcript?.text == "Saved")

        var cache = CalendarCache()
        cache.events = [first, occurrence]
        recording.calendarEvent = first
        cache.prune(now: start.addingTimeInterval(60 * 86400), recordings: [recording])
        precondition(cache.events.map(\.id) == [first.id], "Only linked old events survive cleanup")
        cache.prune(now: start.addingTimeInterval(60 * 86400), recordings: [])
        precondition(cache.events.isEmpty)
        let afterCleanup = try store.loadAll()
        precondition(afterCleanup.count == 1, "Calendar cleanup must not delete recordings")

        let reminder = MeetingReminder(event: first, phase: .start)
        let soonReminder = MeetingReminder(event: first, phase: .soon, leadMinutes: 6)
        var states: [String: ReminderDisposition] = [:]
        precondition(ReminderPolicy.dueDate(reminder, states: states, now: start) == start)
        precondition(ReminderPolicy.dueDate(soonReminder, states: states, now: start.addingTimeInterval(-600)) == start.addingTimeInterval(-360))
        precondition(ReminderPolicy.dueDate(soonReminder, states: states, now: start) == nil, "Soon reminders must expire when the meeting starts")
        let snooze = start.addingTimeInterval(180)
        states[reminder.id] = ReminderDisposition(snoozedUntil: snooze)
        let restoredStates = try JSONDecoder().decode([String: ReminderDisposition].self, from: JSONEncoder().encode(states))
        precondition(ReminderPolicy.dueDate(reminder, states: restoredStates, now: start) == snooze)
        precondition(ReminderPolicy.dueDate(reminder, states: states, now: first.end) == nil, "Wake must not show ended meeting start")
        states[reminder.id] = ReminderDisposition(dismissed: true)
        precondition(ReminderPolicy.dueDate(reminder, states: states, now: start) == nil)
        let endReminder = MeetingReminder(event: first, phase: .end)
        precondition(endReminder.id != reminder.id)
        let oldRecordingEnd = MeetingReminder(event: first, phase: .end, recordingID: UUID())
        let newRecordingEnd = MeetingReminder(event: first, phase: .end, recordingID: UUID())
        states[oldRecordingEnd.id] = ReminderDisposition(dismissed: true)
        precondition(ReminderPolicy.dueDate(oldRecordingEnd, states: states, now: first.end) == nil)
        precondition(ReminderPolicy.dueDate(newRecordingEnd, states: states, now: first.end) == first.end,
                     "Dismissing the old recording's end reminder must not suppress a new recording's reminder")
        states[newRecordingEnd.id] = ReminderDisposition(snoozedUntil: first.end.addingTimeInterval(180))
        precondition(ReminderPolicy.dueDate(newRecordingEnd, states: states, now: first.end) == first.end.addingTimeInterval(180))
        var moved = first
        moved.end = first.end.addingTimeInterval(600)
        precondition(MeetingReminder(event: moved, phase: .end).id != endReminder.id)
        var settings = CalendarSettings()
        settings.remindStart = false
        settings.remindSoon = false
        precondition(ReminderPolicy.candidates(events: [first], active: nil, settings: settings).isEmpty)
        precondition(ReminderPolicy.candidates(events: [first], active: first, settings: settings).count == 1)
        settings.remindEnd = false
        settings.remindSoon = true
        settings.soonMinutes = 6
        let soonCandidates = ReminderPolicy.candidates(events: [first], active: nil, settings: settings)
        precondition(soonCandidates.count == 1 && soonCandidates[0].phase == .soon && soonCandidates[0].leadMinutes == 6)
        var declined = first
        declined.decision = "no"
        settings.remindStart = true
        precondition(ReminderPolicy.candidates(events: [declined], active: nil, settings: settings).isEmpty)
        var cancelled = first
        cancelled.cancelled = true
        precondition(!cancelled.shouldRemind)
        precondition(ReminderPolicy.candidates(events: [cancelled], active: cancelled, settings: settings).isEmpty)
        var allDay = first
        allDay.allDay = true
        precondition(!allDay.shouldRemind)

        let moscow = CalendarParser.date("2026-09-30T15:00:00", timezone: "Europe/Moscow")!
        let utc = CalendarParser.date("2026-09-30T12:00:00Z", timezone: "UTC")!
        precondition(moscow == utc, "Header timezone controls timestamps without offset")
        precondition(CalendarEvent.videoProvider(URL(string: "https://zoom.us.evil.example/123")!) == nil)
        precondition(CalendarEvent.videoProvider(URL(string: "https://telemost.yandex.ru/j/fixture")!) == "Телемост")
        precondition(CalendarEvent.videoProvider(URL(string: "https://example.zoom.us/j/fixture")!) == "Zoom")
        let calls = CalendarParser.calls(description: "Ссылка на звонок: https://zoom.us/j/123\nПароль: first", urls: [])
        precondition(calls.count == 1 && calls[0].password == "first")
        precondition(CalendarParser.links("javascript:alert(1)").isEmpty)
        print("Calendar identity, reminders, retention, timezone and links passed")
    }
}
