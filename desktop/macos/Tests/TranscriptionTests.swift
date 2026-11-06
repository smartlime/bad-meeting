import AppKit
import Foundation
@testable import BadMeetingKit

@main struct TranscriptionTests {
    nonisolated static func fixtureResponse(_ transcript: Transcript) async throws -> Transcript {
        precondition(!Thread.isMainThread)
        try await Task.sleep(for: .milliseconds(150))
        return transcript
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-transcription-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let settingsSuite = "BadMeeting-speaker-settings-" + UUID().uuidString
        let settingsDefaults = UserDefaults(suiteName: settingsSuite)!
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuite) }
        let settingsModel = AppModel(storeRoot: root.appendingPathComponent("settings"), credentialsDefaults: settingsDefaults, sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture())
        settingsModel.automaticSpeakerNaming = false
        settingsModel.textSettings.providerID = "ollama"
        settingsModel.textConnection.model = "fixture-model"
        settingsModel.transcriptionModel = .elevenLabs
        settingsModel.elevenLabsSettings.language = "rus"
        settingsModel.transcriptionModel = .speechkit
        settingsModel.textSettings.providerID = "openrouter"
        settingsModel.textConnection.model = "fixture-router"
        let restored = AppModel(storeRoot: root.appendingPathComponent("restored"), credentialsDefaults: settingsDefaults, sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture())
        precondition(!restored.automaticSpeakerNaming && restored.transcriptionModel == .speechkit)
        restored.transcriptionModel = .elevenLabs
        restored.textSettings.providerID = "ollama"
        precondition(restored.elevenLabsSettings.language == "rus" && restored.textConnection.model == "fixture-model")
        let words = (0..<50_000).map { TranscriptWord(start: Double($0), end: Double($0 + 1), text: "тест ", type: "word", speakerID: "speaker_0") }
        let transcript = Transcript(text: "Тест", words: words, speakerNames: [:])
        var event = CalendarEvent(remoteID: "test", instanceStart: Date(), start: Date(), end: Date().addingTimeInterval(60), title: "Test")
        event.organizer = CalendarPerson(name: "Алексей", email: "alex@example.test", decision: "yes")
        event.attendees = [CalendarPerson(name: "Алексей", email: "ALEX@example.test", decision: "yes"), CalendarPerson(name: "Мария", email: "maria@example.test", decision: "yes")]
        precondition(event.speakerCandidates.map(\.name) == ["Алексей", "Мария"])
        let recording = Meeting(id: UUID(), createdAt: Date(), title: "Before", status: .ready, sourceName: "Fixture", segments: [AudioSegment(id: UUID(), source: "fixture", fileName: "fixture.caf", startSeconds: 0, durationSeconds: 1)], transcript: transcript, transcriptionError: "old error", calendarEvent: event)
        try store.save(recording)
        let model = AppModel(storeRoot: root, sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture(), transcriptionJob: { _, _ in
            try await Self.fixtureResponse(transcript)
        }, speakerNamingJob: { _, _ in SpeakerResolution(names: ["speaker_0": "Алексей"], evidence: ["speaker_0": "Меня зовут Алексей"]) })
        var largestGap = 0.0
        var ticks = 0
        let heartbeat = Task { @MainActor in
            var previous = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled else { break }
                let now = Date()
                largestGap = max(largestGap, now.timeIntervalSince(previous))
                previous = now
                ticks += 1
            }
        }
        let start = Date()
        model.transcribe(recording)
        let entryTime = Date().timeIntervalSince(start)
        precondition(entryTime < 0.05, "Starting transcription must not encode or save a large manifest on the main thread")
        let deadline = Date().addingTimeInterval(15)
        while !model.transcribingIDs.isEmpty || !model.namingSpeakerIDs.isEmpty {
            precondition(Date() < deadline, "Background transcription timed out")
            model.selectRecording(recording.id)
            try await Task.sleep(for: .milliseconds(10))
        }
        heartbeat.cancel()
        await heartbeat.value
        precondition(ticks > 5 && largestGap < 0.15, "Main-thread heartbeat stalled during transcription persistence")
        let saved = try store.loadAll().first!
        precondition(saved.transcriptionError == nil && saved.transcript?.speakerNames["speaker_0"] == "Алексей")
        precondition(saved.transcript?.words.count == 50_000)
        precondition(TranscriptionError.isRetryableNetworkFailure(URLError(.networkConnectionLost)))
        precondition(TranscriptionError.isRetryableNetworkFailure(URLError(.notConnectedToInternet)))
        precondition(!TranscriptionError.isRetryableNetworkFailure(URLError(.badServerResponse)))
        let retryFailure = TranscriptionRetryFailure(attempts: 4, underlyingError: URLError(.notConnectedToInternet))
        precondition(retryFailure.errorDescription?.contains("4 попыток") == true)
        var networkAttempts = 0
        let retryRecording = Meeting(id: UUID(), createdAt: Date(), title: "Retry", status: .ready, sourceName: "Fixture", segments: recording.segments, transcript: nil, transcriptionError: nil)
        try store.save(retryRecording)
        let retryModel = AppModel(storeRoot: root, sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture(), transcriptionJob: { _, _ in
            networkAttempts += 1
            if networkAttempts < 3 { throw URLError(.networkConnectionLost) }
            return Transcript(text: "Повтор удался", words: [], speakerNames: [:])
        }, transcriptionRetryDelays: [.zero, .zero], speakerNamingJob: { _, _ in SpeakerResolution(names: [:], evidence: [:]) })
        retryModel.transcribe(retryRecording)
        let retryDeadline = Date().addingTimeInterval(2)
        while !retryModel.transcribingIDs.isEmpty {
            precondition(Date() < retryDeadline, "Automatic transcription retry timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(networkAttempts == 3)
        precondition(retryModel.meetings.first(where: { $0.id == retryRecording.id })?.transcript?.text == "Повтор удался")
        let disabledRoot = root.appendingPathComponent("disabled")
        let disabledStore = try MeetingStore(root: disabledRoot)
        try disabledStore.save(recording)
        var namingCalls = 0
        let disabledModel = AppModel(storeRoot: disabledRoot, credentialsDefaults: settingsDefaults, sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture(), transcriptionJob: { _, _ in
            Transcript(text: "Тест", words: Array(words.prefix(2)), speakerNames: [:])
        }, speakerNamingJob: { _, _ in
            namingCalls += 1
            return SpeakerResolution(names: ["speaker_0": "Алексей"], evidence: ["speaker_0": "Тест"])
        })
        disabledModel.transcribe(recording)
        while !disabledModel.transcribingIDs.isEmpty || !disabledModel.namingSpeakerIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(namingCalls == 0 && disabledModel.meetings.first?.transcript?.speakerNames.isEmpty == true)
        disabledModel.identifySpeakerNames(disabledModel.meetings.first!)
        while !disabledModel.namingSpeakerIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(namingCalls == 1 && disabledModel.meetings.first?.transcript?.speakerNames["speaker_0"] == "Алексей")
        disabledModel.transcriptionModel = .speechkit
        disabledModel.textSettings.providerID = "ollama"
        disabledModel.automaticSpeakerNaming = true
        disabledModel.transcribe(disabledModel.meetings.first!)
        while !disabledModel.transcribingIDs.isEmpty || !disabledModel.namingSpeakerIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(namingCalls == 2, "Public text provider must process SpeechKit transcripts when selected")
        model.setSpeakerName("Manual", speakerID: "speaker_0", meetingID: recording.id)
        model.identifySpeakerNames(model.selectedMeeting!)
        while !model.namingSpeakerIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(model.selectedMeeting?.transcript?.speakerNames["speaker_0"] == "Manual")
        precondition(model.selectedMeeting?.transcript?.speakerEvidence?["speaker_0"] == nil)
        let turns = [TranscriptTurn(id: 0, speakerID: "speaker_0", start: 0, text: "Меня зовут Алексей."), TranscriptTurn(id: 1, speakerID: "speaker_1", start: 1, text: "Я Мария.")]
        func response(_ speakers: [[String: Any]]) throws -> Data {
            let content = String(decoding: try JSONSerialization.data(withJSONObject: ["speakers": speakers]), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        }
        let valid: [String: Any] = ["speaker_id": "speaker_0", "name": "Алексей", "confidence": "high", "evidence": [["turn_id": 0, "quote": "Меня зовут Алексей."]]]
        let parsed = try SpeakerResolver.parseResponse(response([valid]), turns: turns, candidates: [])
        precondition(parsed.names == ["speaker_0": "Алексей"])
        var invalid = valid
        invalid["evidence"] = [["turn_id": 0, "quote": "invented evidence"]]
        let rejected = try SpeakerResolver.parseResponse(response([invalid]), turns: turns, candidates: ["Алексей"])
        precondition(rejected.names.isEmpty)
        invalid = valid
        invalid["speaker_id"] = "speaker_1"
        let wrongSpeaker = try SpeakerResolver.parseResponse(response([invalid]), turns: turns, candidates: ["Алексей"])
        precondition(wrongSpeaker.names.isEmpty)
        print("Transcription checks passed: entry \(entryTime)s; main-thread max gap \(largestGap)s; background save, organizer candidates, naming evidence and manual names preserved")
    }
}
