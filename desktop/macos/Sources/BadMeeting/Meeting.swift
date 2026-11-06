import Foundation

enum MeetingStatus: String, Codable {
    case recording
    case ready
    case interrupted
}

struct AudioSegment: Codable, Identifiable {
    let id: UUID
    let source: String
    let fileName: String
    let startSeconds: Double
    let durationSeconds: Double
}

struct TranscriptWord: Codable {
    let start: Double
    let end: Double
    let text: String
    let type: String
    let speakerID: String?

    enum CodingKeys: String, CodingKey {
        case start, end, text, type
        case speakerID = "speaker_id"
    }
}

struct Transcript: Codable {
    let text: String
    let words: [TranscriptWord]
    var speakerNames: [String: String]
    var wordWarning: String? = nil
    var revision: UUID? = nil
    var speakerEvidence: [String: String]? = nil
    var speakerNamingWarning: String? = nil
    var transcriptionProvider: String? = nil

}

struct Meeting: Codable, Identifiable {
    var schemaVersion: Int = 2
    let id: UUID
    let createdAt: Date
    var endedAt: Date? = nil
    var title: String
    var status: MeetingStatus
    var sourceName: String
    var segments: [AudioSegment]
    var transcript: Transcript?
    var transcriptionError: String?
    var calendarEvent: CalendarEvent? = nil
    var sourceChanges: [SourceChange]? = nil
}

extension Meeting {
    var duration: TimeInterval {
        segments.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
    }
}

struct TranscriptTurn: Identifiable {
    let id: Int
    let speakerID: String
    let start: Double
    let text: String
}

enum TranscriptFormatter {
    static func turns(from words: [TranscriptWord]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var speaker = "unknown"
        var content = ""
        var start = 0.0
        var end = 0.0

        func appendTurn() {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                turns.append(TranscriptTurn(id: turns.count, speakerID: speaker, start: start, text: trimmed))
            }
        }

        for word in words {
            if word.type == "audio_event" { continue }
            let nextSpeaker = word.speakerID ?? speaker
            if !content.isEmpty && (nextSpeaker != speaker || word.start - end > 3) {
                appendTurn()
                content = ""
            }
            if content.isEmpty { start = word.start }
            speaker = nextSpeaker
            content += word.text
            end = word.end
        }
        appendTurn()
        return turns
    }

    static func copyText(_ transcript: Transcript) -> String {
        if transcript.words.isEmpty { return transcript.text }
        return turns(from: transcript.words).map { turn in
            let name = transcript.speakerNames[turn.speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name?.isEmpty == false ? name! : turn.speakerID): \(turn.text)"
        }.joined(separator: "\n\n")
    }
}


extension Date {
    func meetingFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(Locale(identifier: "ru_RU")))
    }
}
