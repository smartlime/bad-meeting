@testable import BadMeetingKit
import AppKit
import SwiftUI

@main
struct AgendaInteractionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let delegate = InteractionAppDelegate()
        NSApp.delegate = delegate
        Task { @MainActor in
            do {
                try await runChecks()
                exit(0)
            } catch {
                fputs("Native interaction test failed: \(error)\n", stderr)
                exit(1)
            }
        }
        withExtendedLifetime(delegate) { NSApp.run() }
        fatalError("The application loop stopped before checks completed")
    }

    @MainActor static func runChecks() async throws {
        NSApp.activate(ignoringOtherApps: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-interaction-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(36000)
        let event = CalendarEvent(remoteID: "fixture", instanceStart: start, start: start, end: start.addingTimeInterval(1800), title: "Meeting", detailsLoaded: true)
        let recording = Meeting(id: UUID(), createdAt: start, title: "Recording", status: .ready, sourceName: "Microphone", segments: [], transcript: nil, transcriptionError: nil)
        try store.save(recording)
        let model = AppModel(storeRoot: root, sourceInventory: { [] }, calendarProvider: OfflineCalendarFixture())
        if CommandLine.arguments.contains("--header-links-only") {
            checkHeaderLinks()
            return
        }
        if CommandLine.arguments.contains("--reminders-only") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            checkReminders(model: model, event: event, window: window)
            window.close()
            return
        }
        model.calendar.cache.settings.connected = true
        model.calendar.cache.events = [event]
        model.selectedDate = start
        model.selectedMeetingID = nil
        let size = NSSize(width: 1200, height: 780)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: MainView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        pump()
        var probeClicked = false
        let probeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        probeWindow.isReleasedWhenClosed = false
        probeWindow.contentView = NSHostingView(rootView: Button("Probe") { probeClicked = true }.frame(width: 300, height: 200))
        probeWindow.makeKeyAndOrderFront(nil)
        pump()
        click(NSPoint(x: 150, y: 100), in: probeWindow)
        guard probeClicked else {
            fputs("Native input is unavailable; run this test outside the sandbox in a graphical macOS session.\n", stderr)
            exit(2)
        }
        probeWindow.close()
        window.makeKeyAndOrderFront(nil)
        pump()
        var failures = 0
        for point in [NSPoint(x: 280, y: 95), NSPoint(x: 455, y: 95), NSPoint(x: 350, y: 85)] {
            model.selectedEventID = nil
            model.selectedMeetingID = nil
            pump()
            click(point, in: window)
            let passed = model.selectedEventID == event.id
            print("Event click \(point): \(passed ? "PASS" : "FAIL")")
            if !passed { failures += 1 }
        }
        for point in [NSPoint(x: 280, y: 185), NSPoint(x: 455, y: 185), NSPoint(x: 350, y: 175)] {
            model.selectedEventID = nil
            model.selectedMeetingID = nil
            pump()
            click(point, in: window)
            let passed = model.selectedMeetingID == recording.id
            print("Recording click \(point): \(passed ? "PASS" : "FAIL")")
            if !passed { failures += 1 }
        }
        for _ in 0..<5 {
            click(NSPoint(x: 455, y: 95), in: window)
            if model.selectedEventID != event.id || model.selectedMeetingID != nil { failures += 1 }
            click(NSPoint(x: 455, y: 185), in: window)
            if model.selectedMeetingID != recording.id || model.selectedEventID != nil { failures += 1 }
        }
        precondition(model.requestRecordingLink([RecordingTransfer(id: recording.id)], to: event))
        pump()
        guard let cancel = buttons().first(where: { $0.title == "Отмена" }) else {
            fputs("The link confirmation must show a Cancel button.\n", stderr)
            exit(1)
        }
        cancel.performClick(nil)
        pump()
        precondition(model.recordingLinkRequest == nil && model.meetings.first?.calendarEvent == nil)
        precondition(model.requestRecordingLink([RecordingTransfer(id: recording.id)], to: event))
        pump()
        guard let confirm = buttons().first(where: { $0.title == "Привязать" }) else {
            fputs("The link confirmation must show a Link button.\n", stderr)
            exit(1)
        }
        confirm.performClick(nil)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            pump()
        }
        precondition(model.meetings.first?.calendarEvent?.id == event.id, "Confirming the native alert must save the link")
        let persisted = try store.loadAll()
        precondition(persisted.first?.calendarEvent?.id == event.id)
        print("Native confirmation cancellation and acceptance passed")
        var callEvent = event
        callEvent.description = "Ссылка на звонок: https://zoom.us/j/123456\nПароль: 001234\nСсылка на звонок: https://telemost.yandex.ru/j/789012\nПароль: second\nДокументы: https://example.test/docs"
        callEvent.videoURLs = CalendarParser.calls(description: callEvent.description, urls: []).map(\.url)
        var openedURLs: [URL] = []
        let callWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        callWindow.isReleasedWhenClosed = false
        let callHosting = NSHostingView(rootView: EventDetailView(model: model, event: callEvent).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20).background(Color.white).environment(\.openURL, OpenURLAction { url in
            openedURLs.append(url)
            return .handled
        }))
        callHosting.sizingOptions = []
        callWindow.contentView = callHosting
        callHosting.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
        callWindow.makeKeyAndOrderFront(nil)
        defer { callWindow.close() }
        pump()
        let bitmap = callHosting.bitmapImageRepForCachingDisplay(in: callHosting.bounds)!
        callHosting.cacheDisplay(in: callHosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/bad-meeting-call-interaction.png"))
        click(NSPoint(x: 90, y: 57), in: callWindow)
        precondition(openedURLs.last == callEvent.videoURLs[0], "Zoom link must open the full original URL")
        click(NSPoint(x: 90, y: 89), in: callWindow)
        precondition(openedURLs.last == callEvent.videoURLs[1])
        let oldClipboard = NSPasteboard.general.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            let restored = oldClipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            NSPasteboard.general.writeObjects(restored)
        }
        click(NSPoint(x: 225, y: 57), in: callWindow)
        precondition(NSPasteboard.general.string(forType: .string) == "001234")
        click(NSPoint(x: 248, y: 89), in: callWindow)
        precondition(NSPasteboard.general.string(forType: .string) == "second")
        pump()
        pump()
        let expandedBitmap = callHosting.bitmapImageRepForCachingDisplay(in: callHosting.bounds)!
        callHosting.cacheDisplay(in: callHosting.bounds, to: expandedBitmap)
        try expandedBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/bad-meeting-call-description.png"))
        clickTextLink(URL(string: "https://example.test/docs")!, in: callWindow)
        precondition(openedURLs.last == URL(string: "https://example.test/docs")!, "Description links must open when clicked")
        let description = linkedDescription(callEvent.description)
        precondition(description.runs.compactMap { $0.link }.contains(URL(string: "https://example.test/docs")!))
        print("Native call fields passed: Zoom/Telemost clicks preserve URLs, each password copies, description links open")
        var savedSnapshot = event
        savedSnapshot.description = "https://example.test/snapshot"
        var snapshotRecording = recording
        snapshotRecording.calendarEvent = savedSnapshot
        let snapshotHosting = NSHostingView(rootView: RecordingDetailView(model: model, recording: snapshotRecording, delete: {}, link: {}).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20).background(Color.white).environment(\.openURL, OpenURLAction { url in
            openedURLs.append(url)
            return .handled
        }))
        snapshotHosting.sizingOptions = []
        callWindow.contentView = snapshotHosting
        snapshotHosting.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
        pump()
        click(NSPoint(x: 24, y: 197), in: callWindow)
        pump()
        pump()
        let snapshotBitmap = snapshotHosting.bitmapImageRepForCachingDisplay(in: snapshotHosting.bounds)!
        snapshotHosting.cacheDisplay(in: snapshotHosting.bounds, to: snapshotBitmap)
        try snapshotBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/bad-meeting-snapshot-links.png"))
        clickTextLink(URL(string: "https://example.test/snapshot")!, in: callWindow)
        precondition(openedURLs.last == URL(string: "https://example.test/snapshot")!, "Saved meeting snapshot links must open when clicked")
        print("Saved meeting snapshot link click passed")
        precondition(MeetingAttendeesView.columns(width: 560) == 3)
        precondition(MeetingAttendeesView.columns(width: 340) == 2)
        precondition(MeetingAttendeesView.visibleCount(total: 15, limit: 15, expanded: false) == 15)
        precondition(MeetingAttendeesView.visibleCount(total: 12, limit: 15, expanded: false) == 12)
        precondition(MeetingAttendeesView.visibleCount(total: 16, limit: 9, expanded: false) == 9)
        precondition(MeetingAttendeesView.visibleCount(total: 25, limit: 9, expanded: true) == 25)
        let participants = (1...25).map { CalendarPerson(name: "Участник \($0)", email: "person\($0)@example.test", decision: "yes") }
        let participantHosting = NSHostingView(rootView: MeetingAttendeesView(attendees: participants).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20).background(Color.white))
        participantHosting.sizingOptions = []
        callWindow.contentView = participantHosting
        participantHosting.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
        pump()
        pump()
        let participantsBitmap = participantHosting.bitmapImageRepForCachingDisplay(in: participantHosting.bounds)!
        participantHosting.cacheDisplay(in: participantHosting.bounds, to: participantsBitmap)
        try participantsBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/bad-meeting-attendees.png"))
        func renderedRows(_ bitmap: NSBitmapImageRep) -> Int {
            var rows = 0
            var previousHasGreen = false
            for y in 0..<bitmap.pixelsHigh {
                let hasGreen = stride(from: 0, to: bitmap.pixelsWide, by: 4).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.greenComponent > color.redComponent + 0.2 && color.greenComponent > color.blueComponent + 0.15
                }
                if hasGreen && !previousHasGreen { rows += 1 }
                previousHasGreen = hasGreen
            }
            return rows
        }
        precondition(renderedRows(participantsBitmap) == 3, "Large attendee lists must initially render three rows")
        click(NSPoint(x: 80, y: 100), in: callWindow)
        pump()
        participantHosting.cacheDisplay(in: participantHosting.bounds, to: participantsBitmap)
        try participantsBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/bad-meeting-attendees-expanded.png"))
        precondition(renderedRows(participantsBitmap) == 9, "Clicking More must render all 25 attendees in nine rows")
        print("Attendee checks passed: configured counts, responsive columns and expansion")
        var descriptionHeight: CGFloat = 0
        let longText = String(repeating: "Длинное описание переносится по ширине окна. ", count: 16)
        let descriptionHosting = NSHostingView(rootView: MeetingDescriptionView(text: longText, previewLines: 3)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { descriptionHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20).background(Color.white))
        descriptionHosting.sizingOptions = []
        callWindow.contentView = descriptionHosting
        descriptionHosting.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
        pump()
        pump()
        let collapsedHeight = descriptionHeight
        precondition(collapsedHeight > 70 && collapsedHeight < 120)
        click(NSPoint(x: 75, y: 26), in: callWindow)
        pump()
        precondition(descriptionHeight > collapsedHeight + 30, "Description must expand after a native click")
        click(NSPoint(x: 80, y: 20 + descriptionHeight - 8), in: callWindow)
        pump()
        precondition(abs(descriptionHeight - collapsedHeight) < 1, "Description must collapse after a native click")
        callWindow.setContentSize(NSSize(width: 380, height: 500))
        pump()
        pump()
        precondition(abs(descriptionHeight - collapsedHeight) < 1, "Wrapped visual lines must keep the same collapsed height after resizing")
        print("Description checks passed: visual line limit, expansion, collapse and narrow-window wrapping")
        var shortHeight: CGFloat = 0
        let shortHosting = NSHostingView(rootView: MeetingDescriptionView(text: "Короткое описание", previewLines: 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shortHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20))
        shortHosting.sizingOptions = []
        callWindow.contentView = shortHosting
        shortHosting.frame = NSRect(x: 0, y: 0, width: 380, height: 500)
        pump()
        pump()
        let initialShortHeight = shortHeight
        precondition(initialShortHeight > 30, "Short descriptions must initially be fully visible")
        click(NSPoint(x: 75, y: 26), in: callWindow)
        pump()
        precondition(shortHeight < 20, "The header must collapse a short description completely")
        click(NSPoint(x: 75, y: 26), in: callWindow)
        pump()
        precondition(abs(shortHeight - initialShortHeight) < 1)
        print("Short description header collapse and expansion passed")

        var numericValue = 12
        let numericHosting = NSHostingView(rootView: NumericSettingField(title: "Count", value: Binding(get: { numericValue }, set: { numericValue = $0 }), range: 1...100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20))
        numericHosting.sizingOptions = []
        callWindow.contentView = numericHosting
        numericHosting.frame = NSRect(x: 0, y: 0, width: 380, height: 500)
        pump()
        let field = descendants(numericHosting).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        callWindow.makeFirstResponder(field)
        pump()
        let editor = field.currentEditor() as! NSTextView
        editor.selectAll(nil)
        editor.insertText("37", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        precondition(numericValue == 37 && editor.string == "37")
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        precondition(numericValue == 37 && editor.string == "37", "Numeric fields must reject letters visibly")
        editor.selectAll(nil)
        editor.insertText("999", replacementRange: NSRange(location: NSNotFound, length: 0))
        callWindow.makeFirstResponder(nil)
        pump()
        precondition(numericValue == 100 && field.stringValue == "100")
        let stepper = descendants(numericHosting).compactMap { $0 as? NSStepper }.first!
        let downY = stepper.bounds.height * (stepper.isFlipped ? 0.75 : 0.25)
        let downPoint = stepper.convert(NSPoint(x: stepper.bounds.midX, y: downY), to: nil)
        click(NSPoint(x: downPoint.x, y: callWindow.contentView!.bounds.height - downPoint.y), in: callWindow)
        pump()
        precondition(numericValue == 99 && field.stringValue == "99", "The field and stepper must stay synchronized")
        callWindow.makeFirstResponder(field)
        pump()
        let emptyEditor = field.currentEditor() as! NSTextView
        emptyEditor.selectAll(nil)
        emptyEditor.deleteBackward(nil)
        callWindow.makeFirstResponder(nil)
        pump()
        precondition(numericValue == 99 && field.stringValue == "99", "An empty edit must restore the current value")
        print("Numeric control checks passed: digit entry, invalid input, bounds, empty edit and stepper synchronization")

        checkReminders(model: model, event: event, window: callWindow)

        guard failures == 0 else { exit(1) }
        print("Native agenda clicks passed")
    }

    @MainActor static func checkHeaderLinks() {
        let clipboard = NSPasteboard.general.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            let restored = clipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            NSPasteboard.general.writeObjects(restored)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for scheme in ["http", "https"] {
            let url = URL(string: scheme + "://telemost.360.yandex.ru/j/123?fixture=full-address")!
            var opened: [URL] = []
            var width: CGFloat = 0
            let hosting = NSHostingView(rootView: MeetingHeaderLink(url: url, title: "Телемост: 123", systemImage: "video")
                .font(.system(size: 13))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
                .environment(\.openURL, OpenURLAction { opened.append($0); return .handled }))
            hosting.sizingOptions = []
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
            window.makeKeyAndOrderFront(nil)
            pump()
            pump()
            precondition(width > 100)
            click(NSPoint(x: 20 + width - 8, y: 30), in: window)
            precondition(NSPasteboard.general.string(forType: .string) == url.absoluteString, "Copy must preserve the full URL")
            precondition(opened.isEmpty, "Copy must not open a URL")
            click(NSPoint(x: 20 + width - 32, y: 30), in: window)
            precondition(opened == [url], "The open icon must open the original URL")
            click(NSPoint(x: 70, y: 30), in: window)
            precondition(opened == [url, url], "The link title must still open the original URL")
        }
        print("Header link checks passed: HTTP/HTTPS open icons, full URL copies, title links and clipboard restoration")
    }

    @MainActor static func checkReminders(model: AppModel, event: CalendarEvent, window callWindow: NSWindow) {
        let reminders = (1...4).map { index -> MeetingReminder in
            var candidate = event
            candidate.remoteID = "overlap-\(index)"
            candidate.title = "Meeting \(index)"
            candidate.videoURLs = [URL(string: "https://zoom.us/j/100\(index)")!]
            return MeetingReminder(event: candidate, phase: .start)
        }
        var chosen: MeetingReminder?
        var chosenURL: URL?
        callWindow.setContentSize(NSSize(width: 520, height: 700))
        let reminderHosting = NSHostingView(rootView: ReminderView(model: model, items: reminders, fullscreen: false, primary: true, preview: true, action: { _, item, url in
            chosen = item
            chosenURL = url
        }))
        reminderHosting.sizingOptions = []
        callWindow.contentView = reminderHosting
        reminderHosting.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        callWindow.makeKeyAndOrderFront(nil)
        pump()
        func press(_ label: String) {
            if let button = buttons().first(where: { $0.title == label }) {
                button.performClick(nil)
                pump()
                return
            }
            let y = 431.0
            switch label {
            case "Следующая встреча": click(NSPoint(x: 480, y: y), in: callWindow)
            case "Предыдущая встреча": click(NSPoint(x: 40, y: y), in: callWindow)
            case "Подключиться": click(NSPoint(x: 140, y: y + 132), in: callWindow)
            default: preconditionFailure("Unexpected reminder button")
            }
        }
        let ordered = ReminderView.prioritized(reminders)
        for index in 0..<4 {
            press("Подключиться")
            precondition(chosen?.id == ordered[index].id && chosenURL == ordered[index].event.calls.first?.url, "Actions must use the displayed meeting and its URL")
            press("Следующая встреча")
        }
        press("Подключиться")
        precondition(chosen?.id == ordered[0].id, "Paging must wrap to the first meeting")
        press("Предыдущая встреча")
        press("Подключиться")
        precondition(chosen?.id == ordered[3].id, "Reverse paging must reach the last meeting")
        click(NSPoint(x: 140, y: 225), in: callWindow)
        press("Подключиться")
        precondition(chosen?.id == ordered[1].id && chosenURL == ordered[1].event.calls.first?.url, "Clicking a list row must select that meeting")
        print("Reminder checks passed: initial selection, all four meetings, both directions, list selection and matching action URLs")

    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor static func clickTextLink(_ url: URL, in window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        for _ in 0..<20 {
            if NSApp.isActive && window.isKeyWindow { break }
            pump()
        }
        guard NSApp.isActive && window.isKeyWindow else {
            fputs("Native test window could not acquire focus.\n", stderr)
            exit(2)
        }
        for view in descendants(window.contentView!).compactMap({ $0 as? NSTextView }) where !view.isHiddenOrHasHiddenAncestor {
            guard let storage = view.textStorage, let layout = view.layoutManager, let container = view.textContainer else { continue }
            var range: NSRange?
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, candidate, stop in
                if value as? URL == url { range = candidate; stop.pointee = true }
            }
            guard let range else { continue }
            precondition((view.linkTextAttributes?[.cursor] as? NSCursor) == NSCursor.pointingHand)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let local = NSPoint(x: view.textContainerOrigin.x + rect.midX, y: view.textContainerOrigin.y + rect.midY)
            let point = view.convert(local, to: nil)
            let parentPoint = window.contentView!.superview!.convert(point, from: nil)
            guard window.contentView!.hitTest(parentPoint) === view else { continue }
            click(NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y), in: window)
            return
        }
        preconditionFailure("Visible text link was not found")
    }

    @MainActor static func buttons() -> [NSButton] {
        func collect(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return NSApp.windows.filter { $0.isVisible }.flatMap { $0.contentView.map(collect) ?? [] }
    }

    @MainActor static func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    @MainActor static func click(_ point: NSPoint, in window: NSWindow) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(down)
        while let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        pump()
    }
}

private final class InteractionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}
