import Foundation
import Darwin

final class MeetingStore {
    let root: URL

    init(root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("BadMeeting/Meetings", isDirectory: true)
        self.root = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func save(_ meeting: Meeting) throws {
        let prepared = try prepareSave(meeting)
        defer { prepared.discard() }
        try prepared.commit()
    }

    func prepareSave(_ meeting: Meeting) throws -> PreparedMeetingSave {
        let directory = directory(for: meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".meeting-\(UUID().uuidString).tmp")
        do {
            let data = try JSONEncoder.meetingEncoder.encode(meeting)
            try data.write(to: temporary)
            return PreparedMeetingSave(temporary: temporary, destination: directory.appendingPathComponent("meeting.json"))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func loadAll() throws -> [Meeting] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            let manifest = directory.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: manifest),
                  var meeting = try? JSONDecoder.meetingDecoder.decode(Meeting.self, from: data)
            else { return nil }
            if meeting.status == .recording {
                meeting.status = .interrupted
                try? save(meeting)
            }
            return meeting
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ meeting: Meeting) throws {
        try FileManager.default.removeItem(at: directory(for: meeting.id))
    }
}

private extension JSONEncoder {
    static var meetingEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var meetingDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct PreparedMeetingSave {
    let temporary: URL
    let destination: URL

    func commit() throws {
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in rename(source!, target!) }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    func discard() { try? FileManager.default.removeItem(at: temporary) }
}
