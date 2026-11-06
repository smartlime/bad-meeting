@testable import BadMeetingKit
import AppKit
import AVFAudio

@main
struct MeetingLinkTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-links-" + UUID().uuidString)
        let suite = "BadMeeting-links-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let stream = URL(string: "https://example.test/live")!
        for description in [
            "Основная трансляция: https://example.test/live",
            "Смотрите трансляцию в браузере https://example.test/live, дополнительные сведения",
            "Смотреть трансляцию в VCONF:\nhttps://example.test/live",
            "Смотреть трансляцию в VCONF:\r\n  https://example.test/live",
            "Основная трансляция: [https://](https://example.test/live)"
        ] {
            precondition(CalendarParser.calls(description: description, urls: []).map(\.url) == [stream], description)
        }
        precondition(CalendarParser.calls(description: "Документы: https://example.test/live", urls: []).isEmpty)
        precondition(CalendarParser.calls(description: "Основная трансляция: javascript:alert(1)", urls: []).isEmpty)
        precondition(CalendarParser.calls(description: "Смотреть трансляцию в VCONF:\nДругой текст\nhttps://example.test/live", urls: []).isEmpty)
        precondition(CalendarParser.calls(description: "Основная трансляция: https://example.test/live", urls: [stream]).count == 1)
        let zoomURL = URL(string: "https://zoom.us/j/123")!
        let telemostURL = URL(string: "https://telemost.yandex.ru/j/123")!
        let telegramURL = URL(string: "https://t.me/example?livestream")!
        let telemost360URLs = ["http", "https"].map { URL(string: $0 + "://telemost.360.yandex.ru/j/123?fixture=1")! }
        for url in telemost360URLs {
            precondition(CalendarEvent.videoProvider(url) == "Телемост")
            precondition(CalendarParser.calls(description: url.absoluteString, urls: []).map(\.url) == [url])
            precondition(CalendarParser.calls(description: "", urls: [url]).map(\.url) == [url])
            precondition(MeetingApplicationLauncher.nativeBundles(for: url).contains("ru.yandex.Telemost"))
        }
        precondition(CalendarEvent.videoProvider(URL(string: "https://telemost.360.yandex.ru.example.test/j/123")!) == nil)
        precondition(MeetingApplicationLauncher.nativeBundles(for: zoomURL) == ["us.zoom.xos"])
        precondition(MeetingApplicationLauncher.nativeBundles(for: telemostURL).contains("ru.yandex.Telemost"))
        precondition(MeetingApplicationLauncher.nativeBundles(for: telegramURL).contains("org.telegram.desktop"))
        precondition(MeetingApplicationLauncher.nativeBundles(for: stream).isEmpty)
        precondition(CalendarEvent.videoProvider(URL(string: "https://zoom.us.example.test/j/123")!) == nil)
        precondition(!ApplicationAudio.belongsToApplication("other.unrecognized.app", target: "browser.fixture"))
        precondition(ApplicationAudio.belongsToApplication("browser.fixture.helper", target: "browser.fixture"))
        let zoom = ApplicationAudioSource(id: 51, name: "Zoom", bundleID: "us.zoom.xos")
        let browser = ApplicationAudioSource(id: 52, name: "Browser", bundleID: "browser.fixture")
        let telegram = ApplicationAudioSource(id: 53, name: "Telegram", bundleID: "org.telegram.desktop")
        let telemost = ApplicationAudioSource(id: 54, name: "Телемост", bundleID: "ru.yandex.Telemost")
        var available: [ApplicationAudioSource] = [zoom, browser, telegram, telemost]
        var launched: [(String, URL?)] = []
        var captured: [String] = []
        var polls = 0
        var delayedSource: ApplicationAudioSource?
        let launcher = MeetingApplicationLauncher(resolve: { url in
            let source: ApplicationAudioSource
            switch CalendarEvent.videoProvider(url) {
            case "Zoom": source = zoom
            case "Telegram": source = telegram
            case "Телемост": source = telemost
            default: source = browser
            }
            return MeetingApplication(bundleID: source.bundleID, name: source.name, applicationURL: root)
        }, launch: { application, url in
            launched.append((application.bundleID, url))
            return true
        }, pause: {
            polls += 1
            if polls == 3, let delayedSource { available.append(delayedSource) }
            try await Task.sleep(for: .milliseconds(5))
        }, attempts: 100)
        let inputs = RecordingInputs(microphonePermission: { true }, startMicrophone: { _ in {} }, startApplication: { source, recorder in
            captured.append(source.bundleID)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            buffer.floatChannelData![0].initialize(repeating: 0.2, count: 1600)
            recorder.append(buffer, source: "application", hostTime: mach_absolute_time())
            return {}
        })
        let model = AppModel(storeRoot: root, credentialsDefaults: defaults, inputs: inputs, sourceInventory: { available }, applicationLauncher: launcher, calendarProvider: OfflineCalendarFixture())
        model.audioStorageFormat = .pcm16
        model.microphoneEnabled = false
        precondition(model.descriptionPreviewLines == 12 && model.attendeesPreviewCount == 9)
        model.descriptionPreviewLines = 6
        model.attendeesPreviewCount = 4
        precondition(defaults.integer(forKey: "BadMeeting.descriptionPreviewLines") == 6)
        precondition(defaults.integer(forKey: "BadMeeting.attendeesPreviewCount") == 4)
        let reloaded = AppModel(storeRoot: root.appendingPathComponent("reload"), credentialsDefaults: defaults, sourceInventory: { [] }, applicationLauncher: launcher, calendarProvider: OfflineCalendarFixture())
        precondition(reloaded.descriptionPreviewLines == 6 && reloaded.attendeesPreviewCount == 4)
        precondition(MeetingAttendeesView.visibleCount(total: 20, limit: 4, expanded: false) == 4)
        precondition(MeetingAttendeesView.visibleCount(total: 20, limit: 4, expanded: true) == 20)
        let now = Date()
        var event = CalendarEvent(remoteID: "fixture", instanceStart: now, start: now, end: now.addingTimeInterval(1800), title: "Fixture", videoURLs: [stream, zoomURL, telegramURL, telemostURL], detailsLoaded: true)
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [event]
        model.selectEvent(event)
        precondition(model.selectedSourceID == browser.id)
        model.selectMeetingLink(event, url: telegramURL)
        await model.recordCurrentMeeting()
        try await wait { model.isRecording }
        precondition(captured.last == telegram.bundleID && model.activeMeeting?.calendarEvent?.id == event.id)
        model.stopRecording()
        model.selectMeetingLink(event, url: telemostURL)
        precondition(model.selectedSourceID == telemost.id)
        for url in telemost360URLs {
            var telemostEvent = event
            telemostEvent.remoteID = "telemost360"
            telemostEvent.videoURLs = [url]
            model.selectEvent(telemostEvent)
            precondition(model.selectedSourceID == telemost.id)
            await model.recordMeeting(telemostEvent, url: url)
            try await wait { model.isRecording }
            precondition(captured.last == telemost.bundleID)
            model.stopRecording()
        }
        model.selectRecordingSource(zoom.id)
        try await Task.sleep(for: .milliseconds(10))
        precondition(model.selectedSourceID == zoom.id && model.selectedMeetingApplication == nil)
        await model.recordCurrentMeeting()
        precondition(captured.last == zoom.bundleID)
        model.stopRecording()

        var otherEvent = event
        otherEvent.remoteID = "other"
        otherEvent.videoURLs = [telegramURL]
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [event, otherEvent]
        model.selectEvent(otherEvent)
        available = [browser]
        polls = 0
        delayedSource = zoom
        model.join(event, url: zoomURL, record: true)
        precondition(model.isJoining && !model.isRecording && model.selectedEventID == event.id)
        try await wait { model.isRecording }
        precondition(polls >= 3 && captured.last == zoom.bundleID)
        precondition(launched.last?.0 == zoom.bundleID && launched.last?.1 == zoomURL)
        model.stopRecording()

        available = [zoom]
        delayedSource = browser
        polls = 0
        event.videoURLs = [stream]
        await model.recordMeeting(event, url: stream)
        try await wait { model.isRecording }
        precondition(captured.last == browser.bundleID && launched.last?.0 == browser.bundleID && launched.last?.1 == nil)
        model.stopRecording()
        let count = captured.count
        model.join(event, url: stream, record: false)
        try await wait { launched.last?.1 == stream }
        precondition(captured.count == count && !model.recordingBusy)

        available = [browser]
        delayedSource = nil
        polls = 0
        model.join(event, url: zoomURL, record: true)
        try await wait { polls >= 12 }
        precondition(!model.isRecording, "Waiting for Zoom must never capture an already running browser")
        model.cancelJoiningRecording()
        available.append(zoom)
        try await Task.sleep(for: .milliseconds(30))
        precondition(!model.recordingBusy && captured.count == count)

        event.end = now.addingTimeInterval(-1)
        model.join(event, url: zoomURL, record: true)
        precondition(model.endedMeetingRecordingRequest != nil)
        await model.resolveEndedMeetingRecording(event, linked: false)
        try await wait { model.isRecording }
        precondition(captured.last == zoom.bundleID && model.activeMeeting?.calendarEvent == nil)
        precondition(launched.last?.1 == zoomURL)
        model.stopRecording()
        print("Meeting link parsing, preferences, source selection, delayed launch, cancellation and ended-meeting actions passed")
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timed out waiting for the recording state")
    }
}
