import AppKit
import SwiftUI
@testable import BadMeetingKit

@main struct SettingsPreview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "BadMeeting-settings-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storeRoot: root, credentialsDefaults: defaults, sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture())
        model.credentials.useAIW = false
        model.calendar.cache.settings.connected = true
        model.calendar.cache.layers = Edition.calendarSources.flatMap { source in
            [CalendarLayer(id: source.id + "-work", name: "Рабочие встречи", sourceID: source.id),
             CalendarLayer(id: source.id + "-personal", name: "Личный", sourceID: source.id)]
        }
        for provider in Edition.speechProviders {
            model.transcriptionModel = provider.id
            try await render(model, section: .processing, to: output.appendingPathComponent("speech-" + provider.id.rawValue + ".png"))
        }
        for provider in Edition.textProviders {
            model.textSettings.providerID = provider.id
            try await render(model, section: .processing, to: output.appendingPathComponent("text-" + provider.id + ".png"))
        }
        for section in [SettingsSection.calendars, .reminders, .advanced] {
            try await render(model, section: section, to: output.appendingPathComponent(section.rawValue + ".png"))
        }
        print("Every registered provider and settings section rendered with synthetic data")
    }
    @MainActor static func render(_ model: AppModel, section: SettingsSection, to url: URL) async throws {
        let size = NSSize(width: 840, height: 650)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SettingsView(model: model, initialSection: section, resolveCredentials: false).environment(\.colorScheme, .light))
        hosting.sizingOptions = []
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        try autoreleasepool {
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }
    }
}
