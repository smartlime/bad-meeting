@testable import BadMeetingKit
import AppKit
import AVFAudio

@main
struct RecordingLifecycleTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wakeRoot = root.appendingPathComponent("wake-without-sleep")
        let wakeInputs = RecordingInputs(microphonePermission: { true }, startMicrophone: { recorder in
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0.25 }
            recorder.append(buffer, source: "microphone", hostTime: mach_absolute_time())
            return {}
        }, startApplication: { _, _ in fatalError("Unexpected application capture") })
        let wakeModel = AppModel(storeRoot: wakeRoot, inputs: wakeInputs, calendarProvider: OfflineCalendarFixture())
        let wakeEvent = CalendarEvent(remoteID: "wake", instanceStart: Date(), start: Date(),
                                     end: Date().addingTimeInterval(1800), title: "Wake", detailsLoaded: true)
        await wakeModel.recordMeeting(wakeEvent)
        let wakeID = wakeModel.recordingID!
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        let recovered = try manifest(root: wakeRoot, id: wakeID)
        precondition(recovered.duration >= 1 && recovered.status == .interrupted && recovered.endedAt != nil,
                     "Wake without a sleep callback must save audio instead of leaving a 0:00 manifest")
        let recoveredFile = wakeRoot.appendingPathComponent(wakeID.uuidString)
            .appendingPathComponent(recovered.segments[0].fileName)
        let decoded = try AVAudioFile(forReading: recoveredFile)
        precondition(decoded.length >= 16_000)
        precondition(wakeModel.recordingID == nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(try! manifest(root: wakeRoot, id: wakeID).segments.count == 1)
        print("Wake fallback saved and finalized the audio exactly once")
        await wakeModel.recordMeeting(wakeEvent)
        let sleepID = wakeModel.recordingID!
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        let beforeWake = try manifest(root: wakeRoot, id: sleepID)
        precondition(beforeWake.status == .ready && beforeWake.duration >= 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        let afterWake = try manifest(root: wakeRoot, id: sleepID)
        precondition(afterWake.status == .ready && afterWake.segments.count == beforeWake.segments.count)
        precondition(afterWake.endedAt == beforeWake.endedAt && wakeModel.recordingID == nil)
        print("Normal sleep/wake preserves finalized audio without restarting capture")
        if CommandLine.arguments.contains("--wake-only") { return }
        var captures = 0
        var starts = 0
        var beforeStart: (() -> Void)?
        let inputs = RecordingInputs(microphonePermission: { true }, startMicrophone: { recorder in
            precondition(captures == 0, "The old audio capture must stop before the next starts")
            beforeStart?()
            captures += 1
            starts += 1
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for index in 0..<1600 { buffer.floatChannelData![0][index] = 0.25 }
            recorder.append(buffer, source: "microphone", hostTime: mach_absolute_time())
            return { captures -= 1 }
        }, startApplication: { _, _ in fatalError("Tests must not capture a real application") })
        let model = AppModel(storeRoot: root, inputs: inputs, calendarProvider: OfflineCalendarFixture())
        let now = Date()
        let first = CalendarEvent(remoteID: "first", instanceStart: now, start: now, end: now.addingTimeInterval(1800), title: "First", detailsLoaded: true)
        var second = first
        second.remoteID = "second"
        second.title = "Second"
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [first, second]

        await model.recordMeeting(first)
        let firstID = model.recordingID!
        model.updateRecording(firstID, title: "Edited title", event: nil, changeLink: false)
        precondition(!model.canRecordMeeting(first) && model.canRecordMeeting(second))
        await model.recordMeeting(first)
        precondition(model.recordingID == firstID && starts == 1)

        beforeStart = {
            let saved = try! manifest(root: root, id: firstID)
            precondition(saved.status == .ready && saved.endedAt != nil && saved.segments.count == 1)
            precondition(saved.title == "Edited title" && saved.calendarEvent?.id == first.id)
            let audio = root.appendingPathComponent(firstID.uuidString).appendingPathComponent(saved.segments[0].fileName)
            precondition((try! AVAudioFile(forReading: audio)).length == 1600)
        }
        await model.recordMeeting(second)
        beforeStart = nil
        let secondID = model.recordingID!
        precondition(secondID != firstID && model.activeMeeting?.calendarEvent?.id == second.id)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        precondition(model.recordingID == nil && captures == 0 && !model.recordingBusy)
        let sleeping = try manifest(root: root, id: secondID)
        precondition(sleeping.status == .ready && sleeping.segments.count == 1 && sleeping.endedAt != nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.recordingID == nil && starts == 2, "Wake must never resume capture")

        await model.recordMeeting(second)
        let resumedID = model.recordingID!
        precondition(resumedID != secondID)
        _ = model.stopRecording()
        await model.recordMeeting(second)
        let restartedID = model.recordingID!
        precondition(restartedID != resumedID)
        _ = model.stopRecording()
        let saved = try MeetingStore(root: root).loadAll()
        precondition(saved.count == 4 && saved.allSatisfy { $0.status == .ready && $0.segments.count == 1 })
        precondition(saved.filter { $0.calendarEvent?.id == second.id }.count == 3)
        model.selectEvent(second)
        precondition(model.selectedMeetingID == restartedID)

        var permission: CheckedContinuation<Bool, Never>?
        var delayed = inputs
        var deferPermission = true
        delayed.microphonePermission = {
            if deferPermission { return await withCheckedContinuation { permission = $0 } }
            return true
        }
        let pendingRoot = root.appendingPathComponent("pending")
        let pendingModel = AppModel(storeRoot: pendingRoot, inputs: delayed, calendarProvider: OfflineCalendarFixture())
        let pending = Task { await pendingModel.recordMeeting(first) }
        while permission == nil { await Task.yield() }
        precondition(pendingModel.isStarting)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        precondition(!pendingModel.recordingBusy)
        deferPermission = false
        await pendingModel.recordMeeting(second)
        let newID = pendingModel.recordingID!
        permission?.resume(returning: true)
        await pending.value
        precondition(pendingModel.recordingID == newID && pendingModel.meetings.count == 1,
                     "A pre-sleep permission response must not start or overwrite a recording")
        _ = pendingModel.stopRecording()
        precondition(captures == 0)
        let telegram = ApplicationAudioSource(id: 10, name: "Telegram", bundleID: "ru.keepcoder.Telegram")
        let zoom = ApplicationAudioSource(id: 20, name: "Zoom", bundleID: "us.zoom.xos")
        var available = [telegram]
        let sourceModel = AppModel(storeRoot: root.appendingPathComponent("sources"), inputs: inputs, sourceInventory: { available }, calendarProvider: OfflineCalendarFixture())
        let sourceMenu = ApplicationSourcePicker(model: sourceModel)
        let sourceMenuCoordinator = sourceMenu.makeCoordinator()
        let sourceMenuButton = NSPopUpButton(frame: .zero, pullsDown: false)
        sourceMenuCoordinator.button = sourceMenuButton
        sourceMenuButton.menu?.delegate = sourceMenuCoordinator
        available = [zoom, telegram]
        sourceMenuCoordinator.menuWillOpen(sourceMenuButton.menu!)
        precondition(sourceModel.sources.contains(where: { $0.bundleID == zoom.bundleID }),
                     "Opening the source menu must refresh applications that started after Bad Meeting")
        precondition(sourceMenuButton.itemTitles.contains("Zoom"))
        await sourceModel.startRecording(event: first, microphoneOnly: true)
        sourceModel.selectedSourceID = zoom.id
        _ = sourceModel.stopRecording()
        guard sourceModel.sources.contains(where: { $0.bundleID == zoom.bundleID }) else {
            fputs("FAIL: Zoom appeared during recording but is missing from the source menu after stop\n", stderr)
            exit(1)
        }
        precondition(sourceModel.selectedSourceID == zoom.id)
        let restartedZoom = ApplicationAudioSource(id: 30, name: "Zoom", bundleID: zoom.bundleID)
        available = [restartedZoom, telegram]
        sourceModel.refreshSources()
        precondition(sourceModel.selectedSourceID == restartedZoom.id, "Refreshing must preserve Zoom selection when its audio process changes")
        print("Source menu checks passed: Zoom appears after stop and selection survives audio process replacement")
        let drag = RecordingTransfer(id: firstID)
        let manifestURL = root.appendingPathComponent(firstID.uuidString).appendingPathComponent("meeting.json")
        let beforeLink = try Data(contentsOf: manifestURL)
        precondition(!model.requestRecordingLink([], to: second))
        precondition(!model.requestRecordingLink([drag, drag], to: second))
        precondition(!model.requestRecordingLink([RecordingTransfer(id: UUID())], to: second))
        precondition(!model.requestRecordingLink([drag], to: first), "Dropping onto the current event must be a no-op")
        precondition(model.requestRecordingLink([drag], to: second))
        precondition(model.recordingLinkRequest?.previousEventTitle == first.title)
        let beforeConfirmation = try Data(contentsOf: manifestURL)
        precondition(beforeConfirmation == beforeLink, "A drop must not save a link before confirmation")
        model.recordingLinkRequest = nil
        let afterCancellation = try Data(contentsOf: manifestURL)
        precondition(afterCancellation == beforeLink, "Cancelling must preserve the previous link")
        precondition(model.requestRecordingLink([drag], to: second))
        let audioURL = root.appendingPathComponent(firstID.uuidString).appendingPathComponent(saved.first { $0.id == firstID }!.segments[0].fileName)
        let audioBeforeLink = try Data(contentsOf: audioURL)
        await model.confirmRecordingLink(model.recordingLinkRequest!)
        let linked = try manifest(root: root, id: firstID)
        let audioAfterLink = try Data(contentsOf: audioURL)
        precondition(linked.calendarEvent?.id == second.id && linked.title == "Edited title")
        let segmentEncoder = JSONEncoder()
        segmentEncoder.outputFormatting = .sortedKeys
        let segmentsBefore = try segmentEncoder.encode(saved.first { $0.id == firstID }!.segments)
        let segmentsAfter = try segmentEncoder.encode(linked.segments)
        precondition(audioBeforeLink == audioAfterLink && segmentsBefore == segmentsAfter)
        precondition(model.recordingLinkRequest == nil && model.selectedEventID == second.id)
        model.updateRecording(firstID, event: nil)
        precondition(model.requestRecordingLink([drag], to: first))
        await model.confirmRecordingLink(model.recordingLinkRequest!)
        let relinked = try manifest(root: root, id: firstID)
        precondition(relinked.calendarEvent?.id == first.id)
        var cancelledTarget = second
        cancelledTarget.cancelled = true
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [first, cancelledTarget]
        precondition(!model.requestRecordingLink([drag], to: cancelledTarget))
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [first, second]
        print("Recording link checks passed: confirmation required, cancel preserves manifest, confirm persists link without changing audio, invalid drops rejected")
        let provider = CalendarAvailabilityFixture(event: first)
        let calendar = CalendarModel(file: root.appendingPathComponent("calendar-availability.json"), provider: provider)
        calendar.cache.settings.connected = true
        calendar.cache.layers = [CalendarLayer(id: "fixture", name: "Fixture")]
        var cachedEvent = first
        cachedEvent.detailsLoaded = false
        calendar.cache.events = [cachedEvent]
        calendar.cache.lastSync = now
        var alerts = 0
        calendar.onError = { _ in alerts += 1 }
        await calendar.refresh()
        precondition(calendar.errorMessage != nil && alerts == 0)
        precondition(calendar.cache.events == [cachedEvent] && calendar.cache.lastSync == now)
        await calendar.refresh(userInitiated: true)
        precondition(calendar.errorMessage != nil && alerts == 0, "Manual retries must not open network-error alerts")
        let offlineDetail = await calendar.loadDetail(cachedEvent)
        precondition(offlineDetail == cachedEvent && alerts == 0)
        provider.unavailable = false
        _ = await calendar.loadDetail(cachedEvent)
        precondition(calendar.errorMessage != nil, "A detail response must not hide an unsuccessful schedule refresh")
        await calendar.refresh()
        precondition(calendar.errorMessage == nil && alerts == 0 && calendar.cache.lastSync! >= now)
        provider.unavailable = true
        var uncached = second
        uncached.detailsLoaded = false
        _ = await calendar.loadDetail(uncached)
        precondition(calendar.errorMessage != nil && alerts == 0, "A detail-only outage must appear inline")
        provider.unavailable = false
        _ = await calendar.loadDetail(uncached)
        precondition(calendar.errorMessage == nil && alerts == 0)
        print("Calendar availability checks passed: silent scheduled/manual/detail failures, cached schedule retained, recovery clears status")
        var past = first
        past.remoteID = "past"
        past.start = now.addingTimeInterval(-3600)
        past.end = now.addingTimeInterval(-1800)
        var accepted = second
        accepted.decision = "accepted"
        accepted.start = now.addingTimeInterval(-600)
        accepted.instanceStart = accepted.start
        var laterAccepted = accepted
        laterAccepted.remoteID = "later-accepted"
        laterAccepted.title = "Later accepted"
        laterAccepted.start = now.addingTimeInterval(-300)
        laterAccepted.end = now.addingTimeInterval(1500)
        laterAccepted.instanceStart = laterAccepted.start
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [past, first, accepted, laterAccepted]
        model.selectEvent(past)
        precondition(model.preferredCurrentEvent(at: now)?.id == laterAccepted.id)
        precondition(model.currentRecordingEvent(at: now)?.id == laterAccepted.id)
        model.selectEvent(first)
        precondition(model.currentRecordingEvent(at: now)?.id == first.id)
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [past, accepted, laterAccepted]
        model.selectEvent(past)
        await model.recordCurrentMeeting()
        precondition(model.activeMeeting?.calendarEvent?.id == laterAccepted.id)
        _ = model.stopRecording()
        var endedFirst = first
        endedFirst.end = past.end
        var endedSecond = accepted
        endedSecond.end = past.end
        var endedLater = laterAccepted
        endedLater.end = past.end
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [past, endedFirst, endedSecond, endedLater]
        await model.recordCurrentMeeting()
        precondition(model.activeMeeting != nil && model.activeMeeting?.calendarEvent == nil)
        _ = model.stopRecording()
        let countBeforeWarning = model.meetings.count
        await model.recordMeeting(past)
        precondition(!model.isRecording && model.meetings.count == countBeforeWarning && model.endedMeetingRecordingRequest?.id == past.id)
        model.endedMeetingRecordingRequest = nil
        precondition(!model.isRecording && model.meetings.count == countBeforeWarning)
        await model.recordMeeting(past)
        await model.resolveEndedMeetingRecording(past, linked: false)
        precondition(model.activeMeeting != nil && model.activeMeeting?.calendarEvent == nil)
        _ = model.stopRecording()
        await model.recordMeeting(past)
        await model.resolveEndedMeetingRecording(past, linked: true)
        precondition(model.activeMeeting?.calendarEvent?.id == past.id)
        var settings = CalendarSettings()
        settings.remindEnd = true
        let historical = ReminderPolicy.candidates(events: [], active: past, settings: settings, recordingID: model.recordingID, recordingStartedAt: model.activeMeeting!.createdAt)
        precondition(!historical.contains { $0.phase == .end })
        let ongoing = ReminderPolicy.candidates(events: [], active: first, settings: settings, recordingID: model.recordingID, recordingStartedAt: now)
        precondition(ongoing.contains { $0.phase == .end })
        _ = model.stopRecording()
        print("Current meeting selection and ended-meeting recording checks passed")
        print("Recording lifecycle checks passed: handover saves audio before capture, sleep finalizes, wake stays idle, repeated event recordings, stale permission cancellation")
    }

    static func manifest(root: URL, id: UUID) throws -> Meeting {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("meeting.json")))
    }
}

private final class CalendarAvailabilityFixture: CalendarProviding {
    var unavailable = true
    let event: CalendarEvent
    init(event: CalendarEvent) { self.event = event }
    func layers(timezone: String, settings: CalendarSettings) async throws -> [CalendarLayer] {
        if unavailable { throw CalendarFailure(message: "maya unavailable") }
        return [CalendarLayer(id: "fixture", name: "Fixture")]
    }
    func events(from: Date, to: Date, settings: CalendarSettings) async throws -> [CalendarEvent] {
        if unavailable { throw CalendarFailure(message: "Calendar API 0: NETWORK — [Errno 8] nodename nor servname provided, or not known") }
        return [event]
    }
    func detail(_ event: CalendarEvent, timezone: String) async throws -> CalendarEvent {
        if unavailable { throw CalendarFailure(message: "maya unavailable") }
        var result = event
        result.detailsLoaded = true
        return result
    }
}
