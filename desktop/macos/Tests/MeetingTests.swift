@testable import BadMeetingKit
import AVFAudio
import Darwin
import Foundation

@main
struct MeetingTests {
    static func main() throws {
        if CommandLine.arguments.contains("--recording-only") {
            try interruptedMeetingSurvivesRestart()
            try emptyRecordingReportsMissingAudio()
            try recordingSegmentIsFinalizedOnStop()
            try finishedRecordingIsNotOverwrittenBySegmentUpdate()
            try audioSegmentsMixIntoOneWaveFile()
            try audioStorageFormatsRoundTrip()
            print("6 recording tests passed")
            return
        }
        fputs("Running recovery test\n", stderr)
        try interruptedMeetingSurvivesRestart()
        try emptyRecordingReportsMissingAudio()
        fputs("Running transcript test\n", stderr)
        speakerNameAppliesToEntireTranscript()
        fputs("Running recording test\n", stderr)
        try recordingSegmentIsFinalizedOnStop()
        fputs("Running recording state test\n", stderr)
        try finishedRecordingIsNotOverwrittenBySegmentUpdate()
        fputs("Running audio test\n", stderr)
        try audioSegmentsMixIntoOneWaveFile()
        fputs("Running Service response test\n", stderr)
        try textOnlyServiceResponseCanBeRead()
        try standardServiceResponseKeepsSpeakers()
        try wrappedServiceResponseKeepsSpeakers()
        try malformedWordResponseKeepsText()
        try missingTranscriptResponseExplainsTheProblem()
        serviceFailureShowsRawResponseInDebugDetails()
        try olderMeetingManifestCanBeRead()
        try audioStorageFormatsRoundTrip()
        print("14 meeting tests passed")
        try calendarTests()
    }

    static func audioStorageFormatsRoundTrip() throws {
        let suite = "BadMeeting-audio-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(AudioStorageFormat.load(from: defaults) == .aac32)
        precondition(defaults.string(forKey: AudioStorageFormat.defaultsKey) == "aac32")
        defaults.set("pcm16", forKey: AudioStorageFormat.defaultsKey)
        precondition(AudioStorageFormat.load(from: defaults) == .pcm16)
        var sizes: [AudioStorageFormat: Int] = [:]
        for storageFormat in AudioStorageFormat.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try MeetingStore(root: root)
            let meeting = Meeting(id: UUID(), createdAt: Date(), title: "Codec", status: .recording,
                                  sourceName: "Fixture", segments: [], transcript: nil, transcriptionError: nil)
            try store.save(meeting)
            let recorder = SegmentedRecorder(meeting: meeting, store: store, format: storageFormat)
            var failure: Error?
            recorder.onFailure = { failure = $0 }
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            let origin = mach_absolute_time()
            for second in 0..<31 {
                for index in 0..<16_000 {
                    buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 16_000)) * 0.25
                }
                recorder.append(buffer, source: "microphone", hostTime: origin + AudioConvertNanosToHostTime(UInt64(second) * 1_000_000_000))
                _ = recorder.snapshot()
            }
            let saved = recorder.finish(interrupted: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            precondition(failure == nil, "Codec write failed: \(String(describing: failure))")
            precondition(saved.segments.count == 2 && saved.segments[0].durationSeconds == 30 && saved.segments[1].durationSeconds == 1)
            var bytes = 0
            for segment in saved.segments {
                precondition(segment.fileName.hasSuffix("." + storageFormat.fileExtension))
                let url = store.directory(for: meeting.id).appendingPathComponent(segment.fileName)
                bytes += try Data(contentsOf: url).count
                let file = try AVAudioFile(forReading: url)
                precondition(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
                precondition(abs(Double(file.length) / 16_000 - segment.durationSeconds) < 0.1)
            }
            sizes[storageFormat] = bytes
            let wave = try AudioAssembler.makeUploadFile(for: saved, in: store.directory(for: meeting.id))
            defer { try? FileManager.default.removeItem(at: wave) }
            let decoded = try AVAudioFile(forReading: wave)
            precondition(abs(Double(decoded.length) / 16_000 - 31) < 0.1)
            print("\(storageFormat.rawValue): 31 seconds, \(bytes) bytes, upload decoded")
        }
        precondition(sizes[.aac32]! < sizes[.pcm16]! / 5)
        precondition(sizes[.aac16]! < sizes[.aac32]!)
    }

    static func interruptedMeetingSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(
            id: UUID(), createdAt: Date(), title: "Meeting", status: .recording,
            sourceName: "Microphone", segments: [], transcript: nil, transcriptionError: nil
        )
        try store.save(meeting)
        guard try store.loadAll().first?.status == .interrupted else {
            fatalError("Recording state was not recovered")
        }
    }

    static func emptyRecordingReportsMissingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(id: UUID(), createdAt: Date(), title: "Empty", status: .recording,
                              sourceName: "Microphone", segments: [], transcript: nil, transcriptionError: nil)
        try store.save(meeting)
        let recorder = SegmentedRecorder(meeting: meeting, store: store)
        var missingAudio = false
        recorder.onFailure = { error in
            if case RecordingError.noAudio = error { missingAudio = true }
        }
        let saved = recorder.finish(interrupted: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(saved.status == .interrupted && saved.endedAt != nil && missingAudio,
                     "An empty recording must not be reported as successfully saved")
        precondition(try! store.loadAll().first?.status == .interrupted)
    }

    static func speakerNameAppliesToEntireTranscript() {
        let words = [
            TranscriptWord(start: 0, end: 1, text: "Hello", type: "word", speakerID: "speaker_0"),
            TranscriptWord(start: 1, end: 2, text: " world", type: "word", speakerID: "speaker_0"),
            TranscriptWord(start: 6, end: 7, text: "Again", type: "word", speakerID: "speaker_0")
        ]
        let transcript = Transcript(text: "Hello world Again", words: words, speakerNames: ["speaker_0": "Alex"])
        guard TranscriptFormatter.copyText(transcript) == "Alex: Hello world\n\nAlex: Again" else {
            fatalError("Speaker name was not applied to every turn")
        }
    }

    static func recordingSegmentIsFinalizedOnStop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(
            id: UUID(), createdAt: Date(), title: "Meeting", status: .recording,
            sourceName: "Microphone", segments: [], transcript: nil, transcriptionError: nil
        )
        try store.save(meeting)
        let recorder = SegmentedRecorder(meeting: meeting, store: store)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for index in 0..<4_800 { buffer.floatChannelData![channel][index] = 0.5 }
        }
        recorder.append(buffer, source: "microphone", hostTime: mach_absolute_time())
        let stopped = recorder.finish(interrupted: false)
        guard stopped.status == .ready, stopped.endedAt != nil, stopped.segments.count == 1,
              FileManager.default.fileExists(
                atPath: store.directory(for: meeting.id).appendingPathComponent(stopped.segments[0].fileName).path
              )
        else {
            let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: meeting.id).path)
            fatalError("Audio segment was not finalized: \(stopped.status), \(stopped.segments.count), \(files)")
        }
    }

    static func finishedRecordingIsNotOverwrittenBySegmentUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(
            id: UUID(), createdAt: Date(), title: "Meeting", status: .recording,
            sourceName: "Microphone", segments: [], transcript: nil, transcriptionError: nil
        )
        try store.save(meeting)
        let recorder = SegmentedRecorder(meeting: meeting, store: store)
        var displayed = meeting
        recorder.onUpdate = { displayed = $0 }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData![0][index] = 0.5 }
        recorder.append(buffer, source: "microphone", hostTime: mach_absolute_time())
        displayed = recorder.finish(interrupted: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard displayed.status == .ready else {
            fatalError("A queued segment update reverted a finished recording to \(displayed.status)")
        }
    }

    static func audioSegmentsMixIntoOneWaveFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        for name in ["microphone.caf", "application.caf"] {
            let file = try AVAudioFile(
                forWriting: root.appendingPathComponent(name), settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            buffer.frameLength = 160
            for index in 0..<160 { buffer.floatChannelData![0][index] = 0.5 }
            try file.write(from: buffer)
            if #available(macOS 15, *) { file.close() }
        }
        let meeting = Meeting(
            id: UUID(), createdAt: Date(), title: "Meeting", status: .ready,
            sourceName: "Application and microphone",
            segments: ["microphone.caf", "application.caf"].map {
                AudioSegment(id: UUID(), source: $0, fileName: $0, startSeconds: 0, durationSeconds: 0.01)
            },
            transcript: nil, transcriptionError: nil
        )
        let wave = try AudioAssembler.makeUploadFile(for: meeting, in: root)
        let data = try Data(contentsOf: wave)
        guard data.count == 44 + 160 * 2,
              String(decoding: data.prefix(4), as: UTF8.self) == "RIFF",
              data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 44, as: Int16.self) }) == 16_000
        else { fatalError("Audio segments were not mixed correctly") }
    }

    static func textOnlyServiceResponseCanBeRead() throws {
        let response = Data(#"{"text":"Привет, мир"}"#.utf8)
        let transcript = try ElevenLabsTranscriber.parseResponse(ProviderResponse.data(response, unwrap: true))
        guard transcript.text == "Привет, мир", transcript.words.isEmpty,
              transcript.wordWarning?.contains("words") == true else {
            fatalError("Service text without word timestamps was not preserved")
        }
    }

    static func malformedWordResponseKeepsText() throws {
        let response = Data(#"{"text":"Привет","words":[{"text":"Привет","end":1,"type":"word"}]}"#.utf8)
        let transcript = try ElevenLabsTranscriber.parseResponse(ProviderResponse.data(response, unwrap: true))
        guard transcript.text == "Привет", transcript.words.isEmpty,
              transcript.wordWarning?.contains("words[0].start") == true else {
            fatalError("A missing word timestamp must be named without discarding the transcript")
        }
    }

    static func standardServiceResponseKeepsSpeakers() throws {
        let response = Data(#"{"text":"Привет","words":[{"start":0,"end":1,"text":"Привет","type":"word","speaker_id":"speaker_0"}]}"#.utf8)
        let transcript = try ElevenLabsTranscriber.parseResponse(ProviderResponse.data(response, unwrap: true))
        guard transcript.words.count == 1, transcript.words[0].speakerID == "speaker_0",
              transcript.wordWarning == nil else {
            fatalError("The standard Service response lost speaker attribution")
        }
    }

    static func wrappedServiceResponseKeepsSpeakers() throws {
        let response = Data(#"{"key":"ELEVENLABS_JFT_KEY_1","response":{"language_code":"rus","text":"Раз, два","words":[{"text":"Раз,","start":7.7,"end":7.92,"type":"word","speaker_id":"speaker_0"},{"text":" ","start":7.92,"end":8.0,"type":"spacing","speaker_id":"speaker_0"},{"text":"два","start":8.0,"end":8.14,"type":"word","speaker_id":"speaker_0"}]},"usage":{"seconds":12.1}}"#.utf8)
        let transcript = try ElevenLabsTranscriber.parseResponse(ProviderResponse.data(response, unwrap: true))
        guard transcript.text == "Раз, два", transcript.words.count == 3,
              transcript.words[0].speakerID == "speaker_0", transcript.wordWarning == nil else {
            fatalError("The Service response wrapper lost the transcript or speaker attribution")
        }
    }

    static func missingTranscriptResponseExplainsTheProblem() throws {
        do {
            _ = try ElevenLabsTranscriber.parseResponse(Data(#"{"status":"ok"}"#.utf8))
            fatalError("An empty transcription response was accepted")
        } catch TranscriptionError.invalidResponse {
            guard TranscriptionError.invalidResponse.localizedDescription.contains("текста") else {
                fatalError("The error does not name the missing transcript")
            }
        }
    }

    static func serviceFailureShowsRawResponseInDebugDetails() {
        let body = #"{"status":"ok","request_id":"sample"}"#
        let failure = ElevenLabsTranscriber.responseFailure(
            TranscriptionError.invalidResponse,
            data: Data(body.utf8), statusCode: 200, contentType: "application/json"
        )
        guard failure.errorDescription == TranscriptionError.invalidResponse.localizedDescription,
              failure.diagnosticDetails.contains("Код HTTP: 200"),
              failure.diagnosticDetails.contains(body),
              !failure.diagnosticDetails.contains("Authorization") else {
            fatalError("The debug description does not show the Service response safely")
        }
    }

    static func olderMeetingManifestCanBeRead() throws {
        let json = #"{"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","createdAt":0,"title":"Old","status":"ready","sourceName":"Microphone","segments":[],"transcript":{"text":"Hello","words":[],"speakerNames":{}},"transcriptionError":null}"#
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        guard meeting.endedAt == nil, meeting.transcript?.wordWarning == nil else {
            fatalError("The new metadata fields broke older meetings")
        }
    }
}
