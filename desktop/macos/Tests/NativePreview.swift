@testable import BadMeetingKit
import AppKit
import SwiftUI

@main
struct NativePreview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        let event = CalendarEvent(remoteID: "fixture", instanceStart: start, start: start, end: start.addingTimeInterval(1800), title: "Обсуждение архитектуры", description: "Обсуждаем запись встреч, календарь и хранение истории.", organizer: CalendarPerson(name: "Алексей Петров", email: "alex@example.test", decision: "yes"), attendees: [CalendarPerson(name: "Мария Иванова", email: "maria@example.test", decision: "yes"), CalendarPerson(name: "Денис Орлов", email: "denis@example.test", decision: "maybe")], room: "https://rooms.example.test/3-14", videoURLs: [URL(string: "https://telemost.yandex.ru/j/fixture")!], calendarURL: URL(string: "https://example.test/calendar/event")!, detailsLoaded: true)
        var callsPreview = event
        callsPreview.description = "Ссылка на звонок: https://yandex.zoom.us/j/123456\nПароль: 001234\n\nСсылка на звонок: http://telemost.360.yandex.ru/j/789012\nПароль: second\nДокументы: https://example.test/docs"
        callsPreview.videoURLs = CalendarParser.calls(description: callsPreview.description, urls: []).map(\.url)
        var recording = Meeting(id: UUID(), createdAt: start, endedAt: start.addingTimeInterval(1700), title: "Обсуждение архитектуры", status: .ready, sourceName: "Zoom и микрофон", segments: [AudioSegment(id: UUID(), source: "microphone", fileName: "segment.aac", startSeconds: 0, durationSeconds: 1700)], transcript: Transcript(text: "Обсудили запись встреч.", words: [TranscriptWord(start: 0, end: 4, text: "Запись должна сохраняться при закрытии крышки ноутбука.", type: "word", speakerID: "speaker_0"), TranscriptWord(start: 5, end: 9, text: "Сохраним аудио сегментами, а сведения о встрече оставим вместе с записью.", type: "word", speakerID: "speaker_1")], speakerNames: ["speaker_0": "Алексей", "speaker_1": "Мария"]), transcriptionError: nil)
        recording.calendarEvent = event
        try store.save(recording)
        try Data(repeating: 0, count: 2048).write(to: store.directory(for: recording.id).appendingPathComponent("segment.aac"))
        let independent = Meeting(id: UUID(), createdAt: start.addingTimeInterval(3600), title: "Обсуждение у рабочего места", status: .ready, sourceName: "Микрофон", segments: [], transcript: nil, transcriptionError: nil)
        try store.save(independent)
        let previewInputs = RecordingInputs(microphonePermission: { true }, startMicrophone: { _ in {} }, startApplication: { _, _ in {} })
        let zoomSource = ApplicationAudioSource(id: 20, name: "Zoom", bundleID: "us.zoom.xos")
        let credentialSuite = "BadMeeting-preview-credentials-" + UUID().uuidString
        let credentialDefaults = UserDefaults(suiteName: credentialSuite)!
        defer { credentialDefaults.removePersistentDomain(forName: credentialSuite) }
        let model = AppModel(storeRoot: root, credentialsDefaults: credentialDefaults, inputs: previewInputs, sourceInventory: { [zoomSource] }, applicationLauncher: MeetingApplicationLauncher(resolve: { _ in MeetingApplication(bundleID: zoomSource.bundleID, name: zoomSource.name, applicationURL: root) }, launch: { _, _ in true }), calendarProvider: PreviewUnavailableCalendar())
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [event]
        let day = model.calendar.displayCalendar.startOfDay(for: start)
        func shifted(_ offset: Int, id: String, cancelled: Bool = false) -> CalendarEvent {
            var result = event
            result.remoteID = id
            result.start = model.calendar.displayCalendar.date(byAdding: .day, value: offset, to: start)!
            result.end = result.start.addingTimeInterval(1800)
            result.instanceStart = result.start
            result.cancelled = cancelled
            return result
        }
        let previous = shifted(-4, id: "previous")
        let cancelled = shifted(-1, id: "cancelled", cancelled: true)
        let next = shifted(3, id: "next")
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [event, previous, cancelled, next]
        precondition(model.calendar.events(on: cancelled.start).isEmpty)
        precondition(model.calendar.adjacentDay(to: day, direction: -1) == model.calendar.displayCalendar.startOfDay(for: previous.start))
        precondition(model.calendar.adjacentDay(to: day, direction: 1) == model.calendar.displayCalendar.startOfDay(for: next.start))
        var cancelledOriginal = event
        cancelledOriginal.cancelled = true
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [cancelledOriginal]
        precondition(model.calendar.events(on: day).isEmpty, "Recording snapshot must not resurrect a cancelled event")
        model.selectRecording(recording.id)
        precondition(model.selectedEvent == nil && model.selectedMeeting != nil)
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [event, previous, next]
        model.selectedDate = day
        model.moveDay(-1)
        precondition(model.selectedDate == model.calendar.displayCalendar.startOfDay(for: previous.start))
        model.moveDay(1)
        precondition(model.selectedDate == day)
        precondition(model.microphoneEnabled)
        model.microphoneEnabled = false
        precondition(model.selectedSourceID != 0 || !model.canStartRecording)
        model.microphoneEnabled = true
        model.selectRecording(recording.id)
        model.calendar.cache.layers = (1...20).map { CalendarLayer(id: String($0), name: "Календарь \($0)") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let attendees133 = (1...142).map { CalendarPerson(name: "Участник \($0)", email: "person\($0)@example.test", decision: "yes") }
        try await render(MeetingAttendeesView(attendees: attendees133).padding(20).background(Color.white), size: NSSize(width: 600, height: 240), to: output.appendingPathComponent("attendees-133.png"))
        let manyAttendees = (1...25).map { CalendarPerson(name: "Участник \($0)", email: "person\($0)@example.test", decision: "yes") }
        for (name, width, count) in [("attendees-three-rows", 600.0, 25), ("attendees-five-rows", 600.0, 15), ("attendees-narrow", 380.0, 25)] {
            try await render(MeetingAttendeesView(attendees: Array(manyAttendees.prefix(count))).padding(20).background(Color.white), size: NSSize(width: width, height: 240), to: output.appendingPathComponent(name + ".png"))
        }
        try await render(EventDetailView(model: model, event: callsPreview).padding(20).background(Color.white), size: NSSize(width: 760, height: 540), to: output.appendingPathComponent("call-fields.png"))
        var layoutPreview = event
        layoutPreview.title = "Еженедельная встреча команды"
        layoutPreview.room = "6.Переговорная"
        layoutPreview.calendarURL = nil
        layoutPreview.description = "Ссылка на видеовстречу: https://zoom.us/j/123456?pwd=example\nПароль: 001234\n\n- ключевые проекты\n- планы команды\n- вопросы по системе и способы решения"
        layoutPreview.videoURLs = CalendarParser.calls(description: layoutPreview.description, urls: []).map(\.url)
        layoutPreview.attendees = ["Евгений Александров", "Андрей Серебрянский", "Александр Константинопольский", "Мария Иванова", "Антон Соколов", "Юрий Синицын", "Егор Петров", "Павел Иванов", "Ася Ассистент"].enumerated().map {
            CalendarPerson(name: $0.element, email: "person\($0.offset)@example.test", decision: $0.offset % 3 == 0 ? "unknown" : "yes")
        }
        for width in [440.0, 535.0, 760.0] {
            try await render(ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(layoutPreview.title).font(.system(size: 23, weight: .semibold))
                    EventDetailView(model: model, event: layoutPreview)
                }.padding(20)
            }.background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: width, height: 650), to: output.appendingPathComponent("meeting-layout-\(Int(width)).png"))
        }
        var longDescription = event
        longDescription.description = String(repeating: "Длинное описание встречи переносится по ширине окна. ", count: 80)
        longDescription.attendees = attendees133
        for width in [480.0, 760.0] {
            try await render(ScrollView { EventDetailView(model: model, event: longDescription).padding(20) }.background(Color.white), size: NSSize(width: width, height: 720), to: output.appendingPathComponent("meeting-long-\(Int(width)).png"))
        }
        try await render(MainView(model: model), size: NSSize(width: 1200, height: 780), to: output.appendingPathComponent("workspace.png"))
        try await render(MainView(model: model), size: NSSize(width: 850, height: 650), to: output.appendingPathComponent("narrow.png"))
        try await render(MainView(model: model), size: NSSize(width: 1200, height: 780), to: output.appendingPathComponent("workspace-dark.png"), colorScheme: .dark)
        model.selectRecording(independent.id)
        model.selectedSourceID = 0
        try await render(MainView(model: model), size: NSSize(width: 1200, height: 780), to: output.appendingPathComponent("standalone.png"))
        var summary = event
        summary.room = ""
        summary.videoURLs = []
        summary.detailsLoaded = false
        let items = [MeetingReminder(event: summary, phase: .start)]
        try await render(ReminderView(model: model, items: items, fullscreen: false, primary: true, preview: false, action: { _, _, _ in }), size: NSSize(width: 520, height: 530), to: output.appendingPathComponent("reminder.png"))
        try await render(ReminderView(model: model, items: [MeetingReminder(event: event, phase: .soon, leadMinutes: 6)], fullscreen: false, primary: true, preview: true, action: { _, _, _ in }), size: NSSize(width: 520, height: 530), to: output.appendingPathComponent("soon-reminder.png"))
        try await render(RecordingStartFailureView(applicationName: "Zoom", action: { _ in }).padding(0), size: NSSize(width: 680, height: 240), to: output.appendingPathComponent("recording-start-failure.png"))
        try await render(ReminderView(model: model, items: items, fullscreen: true, primary: true, preview: false, action: { _, _, _ in }), size: NSSize(width: 1280, height: 800), to: output.appendingPathComponent("fullscreen.png"))
        try await render(ReminderView(model: model, items: [MeetingReminder(event: event, phase: .end)], fullscreen: false, primary: true, preview: true, action: { _, _, _ in }), size: NSSize(width: 520, height: 380), to: output.appendingPathComponent("end-reminder.png"))
        var parallel = event
        parallel.remoteID = "parallel"
        parallel.title = "Планирование недели"
        var accepted = parallel
        accepted.remoteID = "accepted"
        accepted.title = "Принятая встреча"
        accepted.decision = "yes"
        var fourth = parallel
        fourth.remoteID = "fourth"
        fourth.title = "Четвертая встреча"
        let overlapping = [MeetingReminder(event: parallel, phase: .start), MeetingReminder(event: fourth, phase: .start), MeetingReminder(event: accepted, phase: .start), MeetingReminder(event: summary, phase: .start)]
        precondition(ReminderView.prioritized(overlapping).first?.event.id == accepted.id)
        try await render(ReminderView(model: model, items: overlapping, fullscreen: false, primary: true, preview: true, action: { _, _, _ in }), size: NSSize(width: 520, height: 700), to: output.appendingPathComponent("overlap-reminder.png"))
        try await render(ReminderView(model: model, items: overlapping, fullscreen: true, primary: true, preview: true, action: { _, _, _ in }), size: NSSize(width: 1280, height: 900), to: output.appendingPathComponent("overlap-fullscreen.png"))
        model.automaticSpeakerNaming = true
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings.png"))
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-dark.png"), colorScheme: .dark)
        model.automaticSpeakerNaming = false
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-naming-off.png"))
        model.automaticSpeakerNaming = true
        model.credentials.useAIW = false
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-manual-tokens.png"))
        model.transcriptionModel = .speechkit
        model.speechKitSettings.folderID = "example-folder"
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-speechkit-manual.png"))
        model.credentials.useAIW = true
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-speechkit-aiw.png"))
        model.calendar.cache.settings.connected = true
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-speechkit-aiw-calendar.png"))
        model.transcriptionModel = Edition.speechProviders[0].id
        try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-default-aiw-calendar.png"))
        model.calendar.cache.layers = [CalendarLayer(id: "work", name: "Рабочие встречи"), CalendarLayer(id: "team", name: "Команда"), CalendarLayer(id: "projects", name: "Проекты")]
        model.calendar.cache.settings.layerIDs = ["work"]
        for section in [SettingsSection.calendars, .reminders, .advanced] {
            try await render(SettingsView(model: model, initialSection: section, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-" + section.rawValue + ".png"))
        }
        for provider in Edition.speechProviders {
            model.transcriptionModel = provider.id
            model.credentials.useAIW = false
            try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-speech-" + provider.id.rawValue + ".png"))
        }
        for provider in Edition.textProviders {
            model.textSettings.providerID = provider.id
            try await render(SettingsView(model: model, resolveCredentials: false), size: NSSize(width: 840, height: 650), to: output.appendingPathComponent("settings-text-" + provider.id + ".png"))
        }
        model.calendar.cache.settings.connected = false
        try await render(CalendarSelectionPopover(model: model), size: NSSize(width: 392, height: 370), to: output.appendingPathComponent("calendar-selection.png"))
        model.microphoneEnabled = false
        try await render(MainView(model: model), size: NSSize(width: 850, height: 650), to: output.appendingPathComponent("microphone-off.png"))
        model.microphoneEnabled = true
        model.updateRecording(independent.id, event: event)
        precondition(model.meetings.first { $0.id == independent.id }?.calendarEvent?.id == event.id)
        model.updateRecording(independent.id, event: nil)
        precondition(model.meetings.first { $0.id == independent.id }?.calendarEvent == nil)
        model.updateRecording(independent.id, title: "Renamed", event: nil, changeLink: false)
        let persisted = try store.loadAll()
        precondition(persisted.first { $0.id == independent.id }?.title == "Renamed")
        await model.recordMeeting(event)
        model.calendar.cache.events.append(parallel)
        model.selectEvent(parallel)
        try await render(MainView(model: model), size: NSSize(width: 1200, height: 780), to: output.appendingPathComponent("switch-meeting.png"))
        try await render(ReminderView(model: model, items: [MeetingReminder(event: parallel, phase: .start)], fullscreen: false, primary: true, preview: true, action: { _, _, _ in }), size: NSSize(width: 500, height: 460), to: output.appendingPathComponent("switch-reminder.png"))
        _ = model.stopRecording()
        model.selectEvent(event)
        try await render(MainView(model: model), size: NSSize(width: 1200, height: 780), to: output.appendingPathComponent("multiple-recordings.png"))
        model.selectedSourceID = zoomSource.id
        try await render(MainView(model: model), size: NSSize(width: 850, height: 650), to: output.appendingPathComponent("zoom-source.png"))
        model.calendar.cache.settings.connected = true
        await model.calendar.refresh()
        precondition(model.calendar.errorMessage != nil && model.canStartRecording)
        try await render(MainView(model: model), size: NSSize(width: 850, height: 650), to: output.appendingPathComponent("calendar-offline-narrow.png"))
        try await render(MainView(model: model), size: NSSize(width: 1200, height: 780), to: output.appendingPathComponent("calendar-offline.png"))
        model.calendar.cache.settings.connected = false
        print("Native rendering, cancellation visibility, sparse day navigation, microphone selection and recording metadata checks passed")
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, to url: URL, colorScheme: ColorScheme = .light) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, colorScheme).environment(\.controlActiveState, .active))
        hosting.sizingOptions = []
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("Could not allocate native view bitmap") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
        try png.write(to: url)
        window.contentView = nil
        window.close()
    }
}

private struct PreviewUnavailableCalendar: CalendarProviding {
    var failure: CalendarFailure { CalendarFailure(message: "Calendar API 0: NETWORK — [Errno 8] nodename nor servname provided, or not known") }
    func layers(timezone: String, settings: CalendarSettings) async throws -> [CalendarLayer] { throw failure }
    func events(from: Date, to: Date, settings: CalendarSettings) async throws -> [CalendarEvent] { throw failure }
    func detail(_ event: CalendarEvent, timezone: String) async throws -> CalendarEvent { throw failure }
}
