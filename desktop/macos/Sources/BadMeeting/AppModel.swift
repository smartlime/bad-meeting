import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Combine

@MainActor
final class RecordingMeter: ObservableObject {
    @Published var level: Float = 0
}

private struct JoiningMeeting {
    let id: UUID
    let event: CalendarEvent
    let url: URL
    let application: MeetingApplication
    let linkRecording: Bool
    var applicationName: String { application.name }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var sources: [ApplicationAudioSource] = []
    @Published private(set) var recordingID: UUID?
    let meter = RecordingMeter()
    @Published private(set) var transcribingIDs: Set<UUID> = []
    @Published private(set) var namingSpeakerIDs: Set<UUID> = []
    private var meetingVersions: [UUID: Int] = [:]
    private let transcriptionJob: ((Meeting, URL) async throws -> Transcript)?
    @Published var transcriptionModel: TranscriptionModel {
        didSet { credentialsDefaults.set(transcriptionModel.rawValue, forKey: "BadMeeting.transcriptionModel") }
    }
    @Published var speechKitSettings: SpeechKitSettings {
        didSet { speechKitSettings.save(to: credentialsDefaults) }
    }
    @Published private(set) var transcriptionProgress: [UUID: String] = [:]
    private let transcriptionRetryDelays: [Duration]
    private let speakerNamingJob: ((Transcript, CalendarEvent?) async throws -> SpeakerResolution)?
    @Published var automaticSpeakerNaming: Bool {
        didSet { credentialsDefaults.set(automaticSpeakerNaming, forKey: "BadMeeting.automaticSpeakerNaming") }
    }
    @Published var textSettings: TextModelSettings {
        didSet { textSettings.save(to: credentialsDefaults) }
    }
    @Published var speechSettings: [String: ElevenLabsSettings] {
        didSet { credentialsDefaults.set(try? JSONEncoder().encode(speechSettings), forKey: "BadMeeting.speechSettings") }
    }
    var elevenLabsSettings: ElevenLabsSettings {
        get { speechSettings[transcriptionModel.rawValue] ?? ElevenLabsSettings() }
        set { speechSettings[transcriptionModel.rawValue] = newValue }
    }
    var textConnection: TextConnectionSettings {
        get { textSettings.connection(for: textSettings.provider) }
        set { textSettings.connections[textSettings.provider.id] = newValue }
    }
    func canIdentifySpeakers(_ transcript: Transcript) -> Bool { textSettings.provider.acceptsTranscript(transcript) }

    @Published var recordingLinkRequest: RecordingLinkRequest?
    @Published var endedMeetingRecordingRequest: CalendarEvent?
    @Published var selectedMeetingID: UUID?
    @Published var descriptionPreviewLines: Int {
        didSet { credentialsDefaults.set(descriptionPreviewLines, forKey: "BadMeeting.descriptionPreviewLines") }
    }
    @Published var attendeesPreviewCount: Int {
        didSet { credentialsDefaults.set(attendeesPreviewCount, forKey: "BadMeeting.attendeesPreviewCount") }
    }
    @Published private(set) var selectedMeetingURL: URL?
    @Published private(set) var selectedMeetingApplication: MeetingApplication?
    private let applicationLauncher: MeetingApplicationLauncher
    private var sourceSelectionRevision = 0
    private var endedMeetingLink: (url: URL, openingLink: Bool)?
    @Published var selectedSourceID: AudioObjectID = 0
    @Published var microphoneEnabled = true {
        didSet { normalizeSourceSelection() }
    }
    @Published private(set) var isJoining = false
    var recordingBusy: Bool { isRecording || isStarting || isJoining }
    var canStartRecording: Bool { !recordingBusy && (selectedMeetingApplication != nil || microphoneEnabled || sources.contains { $0.id == selectedSourceID }) }

    func canRecordMeeting(_ event: CalendarEvent, openingVideo: Bool = false) -> Bool {
        !isStarting && !event.cancelled && activeMeeting?.calendarEvent?.id != event.id &&
        (openingVideo || !event.calls.isEmpty || microphoneEnabled || sources.contains { $0.id == selectedSourceID })
    }

    private let credentialWriter: @Sendable (String, CredentialService) async throws -> Void
    private let credentialsDefaults: UserDefaults
    @Published var credentials: CredentialSettings {
        didSet { credentials.save(to: credentialsDefaults) }
    }

    @Published private(set) var credentialRevision = UUID()

    func saveCredential(_ value: String, for service: CredentialService) async throws {
        try await credentialWriter(value, service)
        credentials.clearLegacy(service, from: credentialsDefaults)
        credentialRevision = UUID()
    }

    func deleteCredential(_ service: CredentialService) async throws {
        try await Task.detached { try CredentialKeychain.delete(service) }.value
        credentials.clearLegacy(service, from: credentialsDefaults)
        credentialRevision = UUID()
    }

    @Published var audioStorageFormat = AudioStorageFormat.load() {
        didSet { UserDefaults.standard.set(audioStorageFormat.rawValue, forKey: AudioStorageFormat.defaultsKey) }
    }

    @Published var debugMode = UserDefaults.standard.bool(forKey: "BadMeeting.debugMode") {
        didSet { UserDefaults.standard.set(debugMode, forKey: "BadMeeting.debugMode") }
    }

    let calendar: CalendarModel
    @Published var selectedDate = Date()
    @Published var selectedEventID: String?
    @Published var showingAllRecordings = false
    @Published private(set) var isStarting = false
    @Published var sourceNotice: String?
    var showMainWindow: (() -> Void)?
    var showSettingsWindow: (() -> Void)?
    lazy var reminders = MeetingReminderController(model: self)
    private var calendarSubscription: AnyCancellable?
    private var joinTask: Task<Void, Never>?
    private var joinRequestID: UUID?
    private var joiningMeeting: JoiningMeeting?
    private var startRequestID: UUID?
    private var wakeObserver: NSObjectProtocol?

    var selectedEvent: CalendarEvent? { calendar.visibleEvents.first { $0.id == selectedEventID } }
    var activeMeeting: Meeting? { meetings.first { $0.id == recordingID } }

    private let errorPresenter = ErrorPresenter()
    private var store: MeetingStore?
    private var recorder: SegmentedRecorder?
    private let inputs: RecordingInputs
    private let sourceInventory: () -> [ApplicationAudioSource]
    private var stopMicrophone: (() -> Void)?
    private var stopApplicationAudio: (() -> Void)?
    private var sleepObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    var isRecording: Bool { recordingID != nil }
    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedMeetingID } }

    func storagePath(for meeting: Meeting) -> String? {
        store?.directory(for: meeting.id).path
    }

    func storageSize(for meeting: Meeting) -> Int64 {
        guard let store else { return 0 }
        let directory = store.directory(for: meeting.id)
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { total, file in
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { return total }
            return total + Int64(values?.fileSize ?? 0)
        }
    }

    init(storeRoot: URL? = nil, credentialsDefaults: UserDefaults = .standard, inputs: RecordingInputs? = nil, sourceInventory: @escaping () -> [ApplicationAudioSource] = ApplicationAudio.selectableSources,
         applicationLauncher: MeetingApplicationLauncher? = nil,
         calendarProvider: any CalendarProviding = CombinedCalendarProvider(),
         transcriptionJob: ((Meeting, URL) async throws -> Transcript)? = nil,
         transcriptionRetryDelays: [Duration] = [.zero, .seconds(5), .seconds(20)],
         speakerNamingJob: ((Transcript, CalendarEvent?) async throws -> SpeakerResolution)? = nil,
         credentialWriter: @escaping @Sendable (String, CredentialService) async throws -> Void = { value, service in
             try await Task.detached { try CredentialKeychain.save(value, for: service) }.value
         }) {
        self.applicationLauncher = applicationLauncher ?? .live
        self.descriptionPreviewLines = max(1, credentialsDefaults.object(forKey: "BadMeeting.descriptionPreviewLines") as? Int ?? 12)
        self.attendeesPreviewCount = max(1, credentialsDefaults.object(forKey: "BadMeeting.attendeesPreviewCount") as? Int ?? 9)
        self.credentialWriter = credentialWriter
        self.credentialsDefaults = credentialsDefaults
        self.transcriptionModel = TranscriptionModel(rawValue: credentialsDefaults.string(forKey: "BadMeeting.transcriptionModel") ?? "") ?? Edition.speechProviders[0].id
        self.speechKitSettings = SpeechKitSettings.load(from: credentialsDefaults)
        self.automaticSpeakerNaming = credentialsDefaults.object(forKey: "BadMeeting.automaticSpeakerNaming") as? Bool ?? true
        self.textSettings = TextModelSettings.load(from: credentialsDefaults)
        self.speechSettings = credentialsDefaults.data(forKey: "BadMeeting.speechSettings").flatMap { try? JSONDecoder().decode([String: ElevenLabsSettings].self, from: $0) } ?? [:]
        self.credentials = CredentialSettings.load(from: credentialsDefaults)
        self.transcriptionJob = transcriptionJob
        self.transcriptionRetryDelays = transcriptionRetryDelays
        self.speakerNamingJob = speakerNamingJob
        self.inputs = inputs ?? .live
        self.sourceInventory = sourceInventory
        calendar = CalendarModel(file: storeRoot?.appendingPathComponent("calendar.json"), provider: calendarProvider)
        do {
            let store = try MeetingStore(root: storeRoot)
            self.store = store
            meetings = try store.loadAll()
            selectedMeetingID = meetings.first?.id
        } catch {
            store = nil
            report(error, context: "Не удалось открыть список записей")
        }
        calendar.recordings = { [weak self] in self?.meetings ?? [] }
        calendar.onError = { [weak self] in self?.report($0, context: "Ошибка календаря") }
        calendar.onChange = { [weak self] in self?.reminders.reschedule() }
        calendarSubscription = calendar.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        calendar.prune()
        calendar.start()
        reminders.reschedule()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stopRecording(interrupted: true) }
            Task { @MainActor in
                guard let self else { return }
                await self.calendar.refresh()
                self.reminders.reschedule()
            }
        }
        refreshSources()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stopRecording() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stopRecording(interrupted: true) }
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    func refreshSources() {
        updateSources(sourceInventory())
    }

    private func updateSources(_ available: [ApplicationAudioSource], selecting source: ApplicationAudioSource? = nil) {
        let selectedBundle = source?.bundleID ?? sources.first(where: { $0.id == selectedSourceID })?.bundleID
        sources = available
        if let selectedBundle, let current = sources.first(where: { $0.bundleID == selectedBundle }) {
            selectedSourceID = current.id
        }
        normalizeSourceSelection()
    }

    func selectRecordingSource(_ id: AudioObjectID) {
        sourceSelectionRevision += 1
        selectedMeetingApplication = nil
        selectedSourceID = id
    }

    func selectMeetingLink(_ event: CalendarEvent, url: URL?) {
        sourceSelectionRevision += 1
        selectedMeetingURL = url
        selectedMeetingApplication = url.flatMap(applicationLauncher.resolve)
        if !recordingBusy { refreshSources() }
    }

    func normalizeSourceSelection() {
        if let application = selectedMeetingApplication {
            selectedSourceID = application.source(in: sources)?.id ?? 0
            return
        }
        if !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = microphoneEnabled ? 0 : (ApplicationAudio.preferredSource(from: sources)?.id ?? sources.first?.id ?? 0)
        }
    }

    func moveDay(_ direction: Int) {
        guard let date = calendar.adjacentDay(to: selectedDate, direction: direction) else { return }
        selectDay(date)
    }

    func selectDay(_ date: Date) {
        selectedDate = date
        showingAllRecordings = false
        selectedEventID = nil
        selectedMeetingID = nil
        selectedMeetingURL = nil
        selectedMeetingApplication = nil
        normalizeSourceSelection()
    }

    func toggleDebugMode() { debugMode.toggle() }

    func report(_ error: Error, context: String? = nil, retry: (() -> Void)? = nil) {
        errorPresenter.present(error, context: context, debugMode: debugMode, retry: retry)
    }

    func startRecording(event: CalendarEvent? = nil, microphoneOnly: Bool = false, sourceOverride: ApplicationAudioSource? = nil) async {
        guard recordingID == nil, !isStarting, (!isJoining || microphoneOnly || sourceOverride != nil), let store else { return }
        let requestID = UUID()
        startRequestID = requestID
        isStarting = true
        defer {
            if startRequestID == requestID { isStarting = false; startRequestID = nil }
        }
        sourceNotice = nil
        refreshSources()
        let source = sourceOverride ?? (microphoneOnly ? nil : sources.first { $0.id == selectedSourceID })
        if let sourceOverride { selectedSourceID = sourceOverride.id }
        let includeMicrophone = microphoneEnabled
        guard source != nil || includeMicrophone else {
            report(CalendarFailure(message: "Источник звука не выбран, а микрофон выключен."))
            return
        }
        var microphoneAllowed = false
        if includeMicrophone {
            microphoneAllowed = await inputs.microphonePermission()
        }
        guard startRequestID == requestID, !Task.isCancelled else { return }

        var meeting = Meeting(
            id: UUID(), createdAt: Date(),
            title: event?.title ?? Date.now.meetingFormatted(date: .abbreviated, time: .shortened),
            status: .recording, sourceName: source?.name ?? "Микрофон",
            segments: [], transcript: nil, transcriptionError: nil
        )
        meeting.calendarEvent = event
        do {
            try store.save(meeting)
            let recorder = SegmentedRecorder(meeting: meeting, store: store, format: audioStorageFormat)
            recorder.onUpdate = { [weak self] updated in
                guard let self, let current = self.meetings.first(where: { $0.id == updated.id }), self.recordingID == updated.id else { return }
                var merged = updated
                merged.title = current.title
                merged.calendarEvent = current.calendarEvent
                self.replace(merged)
            }
            recorder.onLevel = { [weak self] level in self?.meter.level = level }
            recorder.onFailure = { [weak self] error in
                self?.report(error, context: "Ошибка записи звука")
            }

            var started = false
            var sourceFailure: Error?
            if let source {
                do {
                    stopApplicationAudio = try inputs.startApplication(source, recorder)
                    started = true
                } catch {
                    sourceFailure = error
                }
            }
            if microphoneAllowed {
                do {
                    stopMicrophone = try inputs.startMicrophone(recorder)
                    started = true
                } catch {
                    if sourceFailure == nil { sourceFailure = error }
                }
            }
            if !started {
                try? store.delete(meeting)
                throw sourceFailure ?? RecordingError.microphoneDenied
            }
            if let source, stopApplicationAudio != nil {
                meeting.sourceName = stopMicrophone == nil ? source.name : "\(source.name) и микрофон"
            } else {
                meeting.sourceName = "Микрофон"
            }
            recorder.setSourceName(meeting.sourceName)
            self.recorder = recorder
            recordingID = meeting.id
            meetings.insert(recorder.snapshot(), at: 0)
            selectRecording(meeting.id)
            if let event, !event.detailsLoaded {
                Task { await enrichRecording(meeting.id, from: event) }
            }
            reminders.reschedule()
            if let sourceFailure { report(sourceFailure) }
        } catch {
            report(error, context: "Не удалось начать запись")
        }
    }

    @discardableResult
    func stopRecording(interrupted: Bool = false) -> Meeting? {
        defer { refreshSources() }
        startRequestID = nil
        isStarting = false
        joinTask?.cancel()
        joinTask = nil
        joinRequestID = nil
        joiningMeeting = nil
        isJoining = false
        guard let recorder else { sourceNotice = nil; return nil }
        recorder.onUpdate = nil
        recorder.onLevel = nil
        stopApplicationAudio?()
        stopMicrophone?()
        stopApplicationAudio = nil
        stopMicrophone = nil
        self.recorder = nil
        recordingID = nil
        meter.level = 0
        let finished = recorder.finish(interrupted: interrupted)
        replace(finished)
        sourceNotice = nil
        reminders.reschedule()
        do { try store?.save(finished); return finished }
        catch { report(error, context: "Не удалось сохранить завершённую запись"); return nil }
    }

    func transcribe(_ meeting: Meeting) {
        guard let store, meeting.status != .recording, !meeting.segments.isEmpty,
              !transcribingIDs.contains(meeting.id), !namingSpeakerIDs.contains(meeting.id) else { return }
        transcribingIDs.insert(meeting.id)
        let directory = store.directory(for: meeting.id)
        let job = transcriptionJob
        let model = transcriptionModel
        let speechSettings = speechKitSettings
        let elevenLabs = elevenLabsSettings
        let credentialSnapshot = credentials
        let retryDelays = transcriptionRetryDelays
        Task {
            defer {
                transcribingIDs.remove(meeting.id)
                transcriptionProgress[meeting.id] = nil
            }
            do {
                try await saveTranscriptChange(meeting.id) { $0.transcriptionError = nil }
                var result: Transcript?
                var failedAttempts = 0
                while result == nil {
                    do {
                        result = try await Task.detached(priority: .utility) {
                            if let job { return try await job(meeting, directory) }
                            return try await model.provider.transcribe(TranscriptionRequest(
                                meeting: meeting, directory: directory, credentials: credentialSnapshot,
                                speechkit: speechSettings, elevenLabs: elevenLabs,
                                progress: { message in await MainActor.run { self.transcriptionProgress[meeting.id] = message } }))
                        }.value
                    } catch {
                        guard !Task.isCancelled else { return }
                        guard TranscriptionError.isRetryableNetworkFailure(error),
                              failedAttempts < retryDelays.count else {
                            if TranscriptionError.isRetryableNetworkFailure(error) {
                                throw TranscriptionRetryFailure(attempts: failedAttempts + 1, underlyingError: error)
                            }
                            throw error
                        }
                        let delay = retryDelays[failedAttempts]
                        failedAttempts += 1
                        try await Task.sleep(for: delay)
                    }
                }
                var transcript = result!
                transcript.revision = UUID()
                transcript.transcriptionProvider = model.rawValue
                try await saveTranscriptChange(meeting.id) {
                    $0.transcript = transcript
                    $0.transcriptionError = nil
                }
                if model == .speechkit { SpeechKitTranscriber.clearCheckpoint(in: directory) }
                transcribingIDs.remove(meeting.id)
                if automaticSpeakerNaming, let saved = meetings.first(where: { $0.id == meeting.id }) { identifySpeakerNames(saved) }
            } catch {
                guard !Task.isCancelled else { return }
                try? await saveTranscriptChange(meeting.id) { $0.transcriptionError = error.localizedDescription }
                report(error, retry: { [self] in
                    guard let current = meetings.first(where: { $0.id == meeting.id }) else { return }
                    self.transcribe(current)
                })
            }
        }
    }

    private func saveTranscriptChange(_ id: UUID, change: (inout Meeting) -> Void) async throws {
        guard let store else { return }
        while var updated = meetings.first(where: { $0.id == id }) {
            let version = meetingVersions[id, default: 0]
            change(&updated)
            let snapshot = updated
            let prepared: PreparedMeetingSave
            do { prepared = try await Task.detached(priority: .utility) { try store.prepareSave(snapshot) }.value }
            catch { throw TranscriptionError.saveTranscript(error.localizedDescription) }
            defer { prepared.discard() }
            guard meetings.contains(where: { $0.id == id }) else { return }
            // Edits made while encoding must survive the background save.
            guard meetingVersions[id, default: 0] == version else { continue }
            do { try prepared.commit() }
            catch { throw TranscriptionError.saveTranscript(error.localizedDescription) }
            replace(updated)
            return
        }
    }

    func identifySpeakerNames(_ meeting: Meeting) {
        guard let transcript = meeting.transcript, canIdentifySpeakers(transcript), !transcript.words.isEmpty,
              !transcribingIDs.contains(meeting.id), !namingSpeakerIDs.contains(meeting.id) else { return }
        namingSpeakerIDs.insert(meeting.id)
        let job = speakerNamingJob
        let provider = textSettings.provider
        let configuration = textConnection
        let credentialSnapshot = credentials
        Task {
            defer { namingSpeakerIDs.remove(meeting.id) }
            do {
                let result = try await Task.detached(priority: .utility) {
                    if let job { return try await job(transcript, meeting.calendarEvent) }
                    return try await SpeakerResolver(provider: provider, configuration: configuration, credentials: credentialSnapshot).resolve(transcript, event: meeting.calendarEvent)
                }.value
                try await saveTranscriptChange(meeting.id) { current in
                    guard current.transcript?.revision == transcript.revision else { return }
                    for speaker in Array((current.transcript?.speakerEvidence ?? [:]).keys) {
                        current.transcript?.speakerNames[speaker] = nil
                        current.transcript?.speakerEvidence?[speaker] = nil
                    }
                    for (speaker, name) in result.names where current.transcript?.speakerNames[speaker]?.isEmpty != false {
                        current.transcript?.speakerNames[speaker] = name
                        if current.transcript?.speakerEvidence == nil { current.transcript?.speakerEvidence = [:] }
                        current.transcript?.speakerEvidence?[speaker] = result.evidence[speaker]
                    }
                    current.transcript?.speakerNamingWarning = result.names.isEmpty
                        ? "Не удалось уверенно определить имена по репликам." : nil
                }
            } catch {
                try? await saveTranscriptChange(meeting.id) { $0.transcript?.speakerNamingWarning = error.localizedDescription }
                report(error, context: "Расшифровка сохранена, но имена спикеров не определены")
            }
        }
    }

    func setSpeakerName(_ name: String, speakerID: String, meetingID: UUID) {
        guard let store, var meeting = meetings.first(where: { $0.id == meetingID }),
              var transcript = meeting.transcript else { return }
        transcript.speakerNames[speakerID] = name
        transcript.speakerEvidence?[speakerID] = nil
        meeting.transcript = transcript
        do {
            try store.save(meeting)
            replace(meeting)
        } catch {
            report(error, context: "Не удалось сохранить имя спикера")
        }
    }

    func copyTranscript(_ meeting: Meeting) {
        guard let transcript = meeting.transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptFormatter.copyText(transcript), forType: .string)
    }

    func delete(_ meeting: Meeting) {
        guard let store, meeting.id != recordingID, !transcribingIDs.contains(meeting.id), !namingSpeakerIDs.contains(meeting.id) else { return }
        do {
            try store.delete(meeting)
            meetings.removeAll { $0.id == meeting.id }
            if selectedMeetingID == meeting.id { selectedMeetingID = nil }
            calendar.prune()
            calendar.persist()
        } catch {
            report(error, context: "Не удалось удалить запись")
        }
    }

    private func enrichRecording(_ id: UUID, from event: CalendarEvent) async {
        let detailed = await calendar.loadDetail(event)
        guard detailed.detailsLoaded, var recording = meetings.first(where: { $0.id == id }),
              recording.calendarEvent?.id == event.id, recording.calendarEvent?.detailsLoaded != true else { return }
        var snapshot = detailed
        if let selectedURL = recording.calendarEvent?.videoURLs.first {
            snapshot.videoURLs = [selectedURL] + detailed.videoURLs.filter { $0 != selectedURL }
        }
        recording.calendarEvent = snapshot
        do {
            if recordingID == id, let recorder {
                recording = try recorder.updateMetadata(title: recording.title, event: snapshot)
            } else { try store?.save(recording) }
            replace(recording)
            reminders.reschedule()
        } catch { report(error, context: "Не удалось сохранить снимок встречи для записи") }
    }

    func selectRecording(_ id: UUID) {
        guard let recording = meetings.first(where: { $0.id == id }) else { return }
        selectedMeetingID = id
        selectedEventID = recording.calendarEvent?.id
        selectedDate = recording.calendarEvent?.start ?? recording.createdAt
    }

    func selectEvent(_ event: CalendarEvent) {
        selectedEventID = event.id
        selectedMeetingID = meetings.first { $0.calendarEvent?.id == event.id }?.id
        selectMeetingLink(event, url: event.calls.first?.url)
        let initialRevision = sourceSelectionRevision
        Task {
            let detail = await calendar.loadDetail(event)
            guard selectedEventID == event.id, sourceSelectionRevision == initialRevision else { return }
            selectMeetingLink(detail, url: detail.calls.first?.url)
        }
    }

    func openMeeting(_ event: CalendarEvent) {
        selectedDate = event.start
        showingAllRecordings = false
        selectEvent(event)
        showMainWindow?()
    }

    func requestRecordingLink(_ items: [RecordingTransfer], to event: CalendarEvent) -> Bool {
        guard items.count == 1, recordingLinkRequest == nil,
              let recording = meetings.first(where: { $0.id == items[0].id }),
              let target = calendar.visibleEvents.first(where: { $0.id == event.id }),
              !target.cancelled, recording.calendarEvent?.id != target.id else { return false }
        recordingLinkRequest = RecordingLinkRequest(recordingID: recording.id, recordingTitle: recording.title,
                                                    previousEventTitle: recording.calendarEvent?.title, event: target)
        return true
    }

    func confirmRecordingLink(_ request: RecordingLinkRequest) async {
        recordingLinkRequest = nil
        guard meetings.contains(where: { $0.id == request.recordingID }) else { return }
        let snapshot = await calendar.loadDetail(request.event)
        guard !snapshot.cancelled, calendar.visibleEvents.contains(where: { $0.id == snapshot.id }) else {
            report(CalendarFailure(message: "Встреча отменена или больше не доступна в календаре. Запись осталась без изменений."), context: "Не удалось привязать запись")
            return
        }
        updateRecording(request.recordingID, event: snapshot)
    }

    func updateRecording(_ id: UUID, title: String? = nil, event: CalendarEvent?, changeLink: Bool = true) {
        guard var recording = meetings.first(where: { $0.id == id }), let store else { return }
        if !changeLink, title == recording.title { return }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recording.title = title }
        if changeLink { recording.calendarEvent = event }
        do {
            if id == recordingID, let recorder {
                recording = try recorder.updateMetadata(title: recording.title, event: recording.calendarEvent)
            } else { try store.save(recording) }
            replace(recording)
            if changeLink { selectRecording(id) }
            calendar.prune()
            calendar.persist()
            reminders.reschedule()
        } catch { report(error, context: "Не удалось сохранить сведения о записи") }
    }

    func stopAndTranscribe() {
        if let recording = stopRecording(), !recording.segments.isEmpty { transcribe(recording) }
    }

    func preferredCurrentEvent(at now: Date = Date()) -> CalendarEvent? {
        let current = calendar.visibleEvents.filter { !$0.cancelled && !$0.allDay && $0.start <= now && now < $0.end }
        return current.sorted {
            let leftAccepted = ["yes", "accepted"].contains($0.decision)
            let rightAccepted = ["yes", "accepted"].contains($1.decision)
            if leftAccepted != rightAccepted { return leftAccepted }
            if $0.start != $1.start { return $0.start > $1.start }
            return $0.id < $1.id
        }.first
    }

    func currentRecordingEvent(at now: Date = Date()) -> CalendarEvent? {
        let current = calendar.visibleEvents.filter { !$0.cancelled && !$0.allDay && $0.start <= now && now < $0.end }
        if let selected = current.first(where: { $0.id == selectedEventID }) { return selected }
        return preferredCurrentEvent(at: now)
    }

    func openCurrentMeeting(at now: Date = Date()) {
        if let event = preferredCurrentEvent(at: now) { openMeeting(event) }
        else { selectDay(now); showMainWindow?() }
    }

    func recordCurrentMeeting() async {
        guard canStartRecording else { return }
        let event = selectedEvent ?? currentRecordingEvent()
        if let event, selectedMeetingApplication != nil {
            await recordMeeting(event)
        } else {
            await startRecording(event: currentRecordingEvent())
        }
    }

    func resolveEndedMeetingRecording(_ event: CalendarEvent, linked: Bool) async {
        endedMeetingRecordingRequest = nil
        if let pending = endedMeetingLink {
            endedMeetingLink = nil
            join(event, url: pending.url, record: true, openingLink: pending.openingLink, confirmedEnded: true, linkRecording: linked)
        } else {
            guard canRecordMeeting(event), prepareForMeetingRecording(event) else { return }
            await startRecording(event: linked ? event : nil)
        }
    }

    func recordMeeting(_ event: CalendarEvent, url: URL? = nil) async {
        guard canRecordMeeting(event) else { return }
        let event = await calendar.loadDetail(event)
        guard canRecordMeeting(event) else { return }
        let selectedURL = selectedMeetingURL.flatMap { candidate in event.calls.contains(where: { $0.url == candidate }) ? candidate : nil }
        let meetingURL = url ?? (selectedEventID == event.id ? selectedURL : nil) ?? event.calls.first?.url
        if event.end <= Date() {
            endedMeetingLink = meetingURL.map { ($0, false) }
            endedMeetingRecordingRequest = event
            showMainWindow?()
            return
        }
        if let meetingURL {
            join(event, url: meetingURL, record: true, openingLink: false)
        } else {
            guard prepareForMeetingRecording(event) else { return }
            await startRecording(event: event)
        }
    }

    private func prepareForMeetingRecording(_ event: CalendarEvent) -> Bool {
        guard canRecordMeeting(event, openingVideo: true) else { return false }
        if isRecording { return stopRecording() != nil }
        stopRecording()
        return true
    }

    func openURL(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            report(CalendarFailure(message: "Ссылка встречи должна использовать HTTP или HTTPS.")); return false
        }
        let opened = NSWorkspace.shared.open(url)
        if !opened { report(CalendarFailure(message: "macOS не удалось открыть ссылку встречи.")) }
        return opened
    }

    func join(_ event: CalendarEvent, url: URL, record: Bool, openingLink: Bool = true, confirmedEnded: Bool = false, linkRecording: Bool = true) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), !event.cancelled else { return }
        if record && event.end <= Date() && !confirmedEnded {
            endedMeetingLink = (url, openingLink)
            guard canRecordMeeting(event, openingVideo: true) else { return }
            endedMeetingRecordingRequest = event
            showMainWindow?()
            return
        }
        guard let application = applicationLauncher.resolve(url) else {
            report(CalendarFailure(message: "Не удалось определить приложение для ссылки встречи."))
            return
        }
        if !record {
            Task {
                if !(await applicationLauncher.launch(application, url)) {
                    report(CalendarFailure(message: "Не удалось открыть приложение " + application.name))
                }
            }
            return
        }
        guard prepareForMeetingRecording(event) else { return }
        selectedEventID = event.id
        selectedDate = event.start
        selectedMeetingID = nil
        selectedMeetingURL = url
        selectedMeetingApplication = application
        refreshSources()
        isJoining = true
        var snapshot = event
        snapshot.videoURLs = [url] + event.videoURLs.filter { $0 != url }
        let request = JoiningMeeting(id: UUID(), event: snapshot, url: url, application: application, linkRecording: linkRecording)
        joinRequestID = request.id
        joiningMeeting = request
        sourceNotice = "Ожидается \(application.name)."
        joinTask = Task { [weak self] in
            guard let self else { return }
            let alreadyRunning = !openingLink && application.source(in: self.sourceInventory()) != nil
            let launched = alreadyRunning ? true : await self.applicationLauncher.launch(application, openingLink ? url : nil)
            guard !Task.isCancelled, self.joinRequestID == request.id else { return }
            guard launched else {
                self.finishJoining(request.id)
                self.report(CalendarFailure(message: "Не удалось открыть приложение " + application.name))
                return
            }
            self.waitForMeetingApplication(request)
        }
    }

    func waitAnotherTwentySeconds() {
        guard let request = joiningMeeting, joinRequestID == request.id else { return }
        waitForMeetingApplication(request)
    }

    func recordOnlyMicrophone() {
        guard let request = joiningMeeting, joinRequestID == request.id else { return }
        finishJoining(request.id)
        Task { await startRecording(event: request.linkRecording ? request.event : nil, microphoneOnly: true) }
    }

    func cancelJoiningRecording() {
        guard let request = joiningMeeting else { return }
        finishJoining(request.id)
    }

    private func waitForMeetingApplication(_ request: JoiningMeeting) {
        joinTask?.cancel()
        sourceNotice = "Ожидается \(request.applicationName)."
        joinTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<self.applicationLauncher.attempts {
                guard !Task.isCancelled, self.joinRequestID == request.id else { return }
                let available = self.sourceInventory()
                if let source = request.application.source(in: available) {
                    self.updateSources(available, selecting: source)
                    await self.startRecording(event: request.linkRecording ? request.event : nil, sourceOverride: source)
                    self.finishJoining(request.id)
                    return
                }
                do { try await self.applicationLauncher.pause() } catch { return }
            }
            guard !Task.isCancelled, self.joinRequestID == request.id else { return }
            self.joinTask = nil
            self.sourceNotice = nil
            self.reminders.presentRecordingStartFailure(applicationName: request.applicationName)
        }
    }

    private func finishJoining(_ requestID: UUID) {
        guard joinRequestID == requestID else { return }
        joinTask?.cancel()
        joinTask = nil
        joinRequestID = nil
        joiningMeeting = nil
        isJoining = false
        sourceNotice = nil
    }

    private func replace(_ meeting: Meeting) {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetingVersions[meeting.id, default: 0] += 1
        meetings[index] = meeting
    }
}
