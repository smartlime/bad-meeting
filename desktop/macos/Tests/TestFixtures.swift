import Foundation
@testable import BadMeetingKit

struct OfflineCalendarFixture: CalendarProviding {
    func layers(timezone: String, settings: CalendarSettings) async throws -> [CalendarLayer] { throw CalendarFailure(message: "Fixture offline") }
    func events(from: Date, to: Date, settings: CalendarSettings) async throws -> [CalendarEvent] { throw CalendarFailure(message: "Fixture offline") }
    func detail(_ event: CalendarEvent, timezone: String) async throws -> CalendarEvent { event }
}
