@testable import BadMeetingKit
import AppKit
import SwiftUI

@main
struct ToolbarLayoutTests: App {
    @StateObject private var model: AppModel
    private let root: URL

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-toolbar-" + UUID().uuidString)
        self.root = root
        _model = StateObject(wrappedValue: AppModel(storeRoot: root,
            inputs: RecordingInputs(microphonePermission: { true }, startMicrophone: { _ in {} }, startApplication: { _, _ in {} }), sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture()))
    }

    var body: some Scene {
        Window("Bad Meeting", id: "main") {
            MainView(model: model).task {
                do {
                    NSApp.setActivationPolicy(.regular)
                    try await Task.sleep(for: .milliseconds(300))
                    let window = NSApp.windows.first { $0.title == "Bad Meeting" }!
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    for width in [1200, 850] {
                        window.setContentSize(NSSize(width: width, height: 780))
                        try await Task.sleep(for: .seconds(1))
                        let before = controlFrame(window)
                        try capture(window, name: "rec-idle-\(width)")
                        await model.recordCurrentMeeting()
                        try await Task.sleep(for: .seconds(2))
                        let after = controlFrame(window)
                        let indicator = itemFrame(window, id: "recording-indicator")
                        fputs("Recording indicator at \(width): \(indicator)\n", stderr)
                        precondition(abs(indicator.midX - window.frame.width / 2) <= 2,
                                     "Recording indicator must remain centered independently of REC")
                        try capture(window, name: "rec-active-\(width)")
                        fputs("Recording toolbar frames at \(width): idle=\(before), recording=\(after)\n", stderr)
                        // Liquid Glass changes group insets by two points; the app's compatibility layout must stay exact.
                        let tolerance: CGFloat = CommandLine.arguments.contains("--legacy-sdk") ? 0.5 : 2
                        precondition(abs(before.minX - after.minX) <= tolerance && abs(before.width - after.width) <= tolerance,
                                     "Record and stop must keep the same position and width")
                        precondition(after.maxX > window.frame.width - 120, "Stop must remain at the right side")
                        _ = model.stopRecording()
                        try await Task.sleep(for: .milliseconds(150))
                        let stopped = controlFrame(window)
                        precondition(abs(before.minX - stopped.minX) <= tolerance && abs(before.width - stopped.width) <= tolerance)
                    }
                    let end = Date().addingTimeInterval(-60)
                    let past = CalendarEvent(remoteID: "past", instanceStart: end.addingTimeInterval(-1800), start: end.addingTimeInterval(-1800), end: end, title: "Ended fixture", detailsLoaded: true)
                    for action in ["Отмена", "Записать без привязки", "Записать во встречу"] {
                        await model.recordMeeting(past)
                        try await Task.sleep(for: .milliseconds(200))
                        let alertButtons = buttons()
                        precondition(["Отмена", "Записать без привязки", "Записать во встречу"].allSatisfy { title in alertButtons.contains { $0.title == title } })
                        alertButtons.first { $0.title == action }!.performClick(nil)
                        try await Task.sleep(for: .milliseconds(200))
                        precondition(model.endedMeetingRecordingRequest == nil)
                        if action == "Отмена" { precondition(!model.isRecording) }
                        else {
                            precondition(model.isRecording)
                            precondition(model.activeMeeting?.calendarEvent?.id == (action == "Записать во встречу" ? past.id : nil))
                            _ = model.stopRecording()
                        }
                    }
                    try? FileManager.default.removeItem(at: root)
                    print("Toolbar layout checks passed")
                    exit(0)
                } catch { fputs("Toolbar test failed: \(error)\n", stderr); exit(1) }
            }
        }.defaultSize(width: 1200, height: 780)
    }

    private func controlFrame(_ window: NSWindow) -> NSRect {
        itemFrame(window, id: "recording-control")
    }

    private func itemFrame(_ window: NSWindow, id: String) -> NSRect {
        guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.contains(id) }), let view = item.view else {
            print("Toolbar items: \(window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? [])")
            fatalError("Missing \(id) toolbar item")
        }
        return view.convert(view.bounds, to: nil)
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func buttons() -> [NSButton] {
        func collect(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return NSApp.windows.filter { $0.isVisible }.flatMap { $0.contentView.map(collect) ?? [] }
    }
}
