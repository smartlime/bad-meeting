import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct RecordingTransfer: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.varnakov.badmeeting.recording"))
            .visibility(.ownProcess)
    }
}

struct RecordingLinkRequest {
    let recordingID: UUID
    let recordingTitle: String
    let previousEventTitle: String?
    let event: CalendarEvent

    var message: String {
        var text = "Запись: \(recordingTitle)\nВстреча: \(event.title)\n\(event.start.meetingFormatted(date: .abbreviated, time: .omitted)), \(event.timeText) (\(event.timezone))"
        if let previousEventTitle { text += "\n\nТекущая привязка к встрече «\(previousEventTitle)» будет заменена." }
        return text
    }
}
