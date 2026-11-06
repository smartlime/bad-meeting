import AppKit
import SwiftUI

@MainActor
final class MeetingReminderController {
    private unowned let model: AppModel
    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var displayed: [MeetingReminder] = []
    private var previewing = false
    private var screenObserver: NSObjectProtocol?
    private var recordingStartPanel: NSPanel?

    init(model: AppModel) {
        self.model = model
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.panels.isEmpty else { return }
                let items = self.displayed
                let preview = self.previewing
                self.closePanels()
                self.present(items, preview: preview)
            }
        }
    }

    func reschedule() {
        timer?.invalidate()
        timer = nil
        let settings = model.calendar.settings
        guard settings.connected else { if !previewing { closePanels() }; return }
        let activeSnapshot = model.activeMeeting?.calendarEvent
        let active = activeSnapshot.flatMap { snapshot in model.calendar.cache.events.first { $0.id == snapshot.id } ?? snapshot }
        let candidates = ReminderPolicy.candidates(events: model.calendar.cache.events, active: active, settings: settings, recordingID: model.recordingID, recordingStartedAt: model.activeMeeting?.createdAt)
        let now = Date()
        let valid = candidates.filter { ReminderPolicy.dueDate($0, states: model.calendar.cache.reminders, now: now) != nil }
        if !previewing, !displayed.isEmpty,
           !displayed.allSatisfy({ shown in valid.contains { $0.id == shown.id } }) { closePanels() }
        let waiting = valid.filter { reminder in !displayed.contains { $0.id == reminder.id } }
        let due = waiting.filter { (ReminderPolicy.dueDate($0, states: model.calendar.cache.reminders, now: now) ?? .distantFuture) <= now }
        if panels.isEmpty, !due.isEmpty {
            let end = due.filter { $0.phase == .end }
            let start = due.filter { $0.phase == .start }
            present(!end.isEmpty ? end : (!start.isEmpty ? start : due.filter { $0.phase == .soon }))
        }
        let next = waiting.compactMap { ReminderPolicy.dueDate($0, states: model.calendar.cache.reminders, now: now) }.filter { $0 > now }.min()
        if let next {
            timer = Timer.scheduledTimer(withTimeInterval: max(0.1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.reschedule() }
            }
            timer?.tolerance = 1
        }
    }

    func preview(end: Bool) {
        closePanels()
        let event = CalendarEvent(remoteID: "preview", instanceStart: Date(), start: Date(), end: Date().addingTimeInterval(1800), title: end ? "Встреча заканчивается" : "Обсуждение проекта", room: "Переговорная")
        present([MeetingReminder(event: event, phase: end ? .end : .start)], preview: true)
    }

    func preview(soon: Bool) {
        guard soon else { preview(end: false); return }
        closePanels()
        let event = CalendarEvent(remoteID: "preview-soon", instanceStart: Date().addingTimeInterval(Double(model.calendar.settings.soonMinutes) * 60), start: Date().addingTimeInterval(Double(model.calendar.settings.soonMinutes) * 60), end: Date().addingTimeInterval(Double(model.calendar.settings.soonMinutes + 30) * 60), title: "Обсуждение проекта", room: "Переговорная")
        present([MeetingReminder(event: event, phase: .soon, leadMinutes: model.calendar.settings.soonMinutes)], preview: true)
    }

    func presentRecordingStartFailure(applicationName: String) {
        recordingStartPanel?.close()
        let size = NSSize(width: 680, height: 240)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let panel = ReminderPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.dismiss = { [weak self] in self?.recordingStartAction(.cancel) }
        let hosting = NSHostingView(rootView: RecordingStartFailureView(applicationName: applicationName) { [weak self] action in
            self?.recordingStartAction(action)
        })
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        if let screen { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)) }
        recordingStartPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func present(_ items: [MeetingReminder], preview: Bool = false) {
        guard !items.isEmpty else { return }
        displayed = items
        previewing = preview
        let isEnd = items[0].phase == .end
        let full = model.calendar.settings.fullscreen(for: items[0].phase)
        let mainScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screens = full ? NSScreen.screens : [mainScreen].compactMap { $0 }
        for screen in screens {
            let primary = screen == mainScreen
            let height = isEnd && items.count == 1 ? 380 : (items.count > 1 ? 700 : 530)
            let size = full ? screen.frame.size : NSSize(width: 520, height: height)
            let panel = ReminderPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.hasShadow = !full
            panel.backgroundColor = .windowBackgroundColor
            panel.dismiss = { [weak self] in self?.act(.dismiss, reminder: nil, url: nil) }
            let hosting = NSHostingView(rootView: ReminderView(model: model, items: items, fullscreen: full, primary: primary, preview: preview) { [weak self] action, item, url in self?.act(action, reminder: item, url: url) })
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hosting
            if full { panel.setFrame(screen.frame, display: true) }
            else { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.maxY - size.height - 24)) }
            panels.append(panel)
            panel.orderFrontRegardless()
            if primary { panel.makeKey() }
        }
    }

    private func closePanels() {
        panels.forEach { $0.close() }
        panels.removeAll()
        displayed.removeAll()
        previewing = false
    }

    private func recordingStartAction(_ action: RecordingStartFailureAction) {
        recordingStartPanel?.close()
        recordingStartPanel = nil
        switch action {
        case .wait: model.waitAnotherTwentySeconds()
        case .microphone: model.recordOnlyMicrophone()
        case .cancel: model.cancelJoiningRecording()
        }
    }

    private func act(_ action: ReminderAction, reminder: MeetingReminder?, url: URL?) {
        if previewing { closePanels(); reschedule(); return }
        if action == .dismiss {
            if let reminder {
                model.calendar.cache.reminders[reminder.id] = ReminderDisposition(dismissed: true)
                let remaining = displayed.filter { $0.id != reminder.id }
                closePanels()
                model.calendar.persist()
                if !remaining.isEmpty { present(remaining) }
                reschedule()
                return
            }
            for item in displayed { model.calendar.cache.reminders[item.id] = ReminderDisposition(dismissed: true) }
        } else if let reminder {
            if action == .snooze {
                model.calendar.cache.reminders[reminder.id] = ReminderDisposition(snoozedUntil: Date().addingTimeInterval(Double(model.calendar.settings.snoozeMinutes) * 60))
            } else {
                model.calendar.cache.reminders[reminder.id] = ReminderDisposition(dismissed: true)
            }
        }
        closePanels()
        model.calendar.persist()
        if let reminder {
            switch action {
            case .open:
                model.openMeeting(reminder.event)
            case .record:
                Task { await model.recordMeeting(reminder.event, url: url) }
            case .join, .joinAndRecord:
                if let url { model.join(reminder.event, url: url, record: action == .joinAndRecord) }
                else if action == .joinAndRecord { Task { await model.recordMeeting(reminder.event, url: url) } }
            case .stop:
                if reminder.recordingID == model.recordingID { model.stopRecording() }
            case .stopAndTranscribe:
                if reminder.recordingID == model.recordingID { model.stopAndTranscribe() }
            case .dismiss, .snooze: break
            }
        }
        reschedule()
    }
}

enum RecordingStartFailureAction { case wait, microphone, cancel }

struct RecordingStartFailureView: View {
    let applicationName: String
    let action: (RecordingStartFailureAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Запись встречи", systemImage: "video.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text("Источник звука \(applicationName) недоступен.")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Отменить запись") { action(.cancel) }
                Button("Записать только микрофон") { action(.microphone) }
                Button("Подождать ещё 20 сек") { action(.wait) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

private final class ReminderPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() } else { super.keyDown(with: event) }
    }
}

enum ReminderAction { case dismiss, snooze, open, record, join, joinAndRecord, stop, stopAndTranscribe }

struct ReminderView: View {
    @ObservedObject var model: AppModel
    let items: [MeetingReminder]
    let fullscreen: Bool
    let primary: Bool
    let preview: Bool
    let action: (ReminderAction, MeetingReminder?, URL?) -> Void
    @State private var selection: String?
    @State private var selectedURL: URL?
    static func prioritized(_ items: [MeetingReminder]) -> [MeetingReminder] {
        items.sorted {
            let leftAccepted = ["yes", "accepted"].contains($0.event.decision)
            let rightAccepted = ["yes", "accepted"].contains($1.event.decision)
            if leftAccepted != rightAccepted { return leftAccepted }
            if $0.event.start != $1.event.start { return $0.event.start < $1.event.start }
            return $0.id < $1.id
        }
    }
    private var prioritizedItems: [MeetingReminder] { Self.prioritized(items) }
    private var selectedID: String? {
        prioritizedItems.first(where: { $0.id == selection })?.id ?? prioritizedItems.first?.id
    }

    private func moveSelection(_ offset: Int) {
        let ordered = prioritizedItems
        guard !ordered.isEmpty else { return }
        let index = ordered.firstIndex(where: { $0.id == selectedID }) ?? 0
        selection = ordered[(index + offset + ordered.count) % ordered.count].id
    }
    private var selected: MeetingReminder? {
        guard let item = prioritizedItems.first(where: { $0.id == selectedID }) else { return nil }
        guard !preview, let current = model.calendar.cache.events.first(where: { $0.id == item.event.id }) else { return item }
        return MeetingReminder(event: current, phase: item.phase, recordingID: item.recordingID, leadMinutes: item.leadMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fullscreen ? 26 : 18) {
            HStack {
                Label(preview ? "Предпросмотр напоминания" : "Bad Meeting", systemImage: "calendar.badge.clock").foregroundStyle(.secondary)
                Spacer()
                Button { action(.dismiss, selected, nil) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть напоминание, Escape")
            }
            if items.count > 1 {
                Text("Встречи: \(items.count)").font(.title2.bold())
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(prioritizedItems) { item in
                                Button { selection = item.id } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.event.title).font(.headline).lineLimit(1)
                                            Text(item.event.timeText).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }.padding(8)
                                        .frame(height: 48)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(selectedID == item.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!primary)
                                    .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                                    .id(item.id)
                            }
                        }
                    }.frame(height: CGFloat(min(items.count, 4)) * 52 - 4)
                        .onChange(of: selectedID) { _, id in
                            if let id { scroll.scrollTo(id, anchor: .center) }
                        }
                }
            }
            if let item = selected {
                VStack(alignment: .leading, spacing: 12) {
                    Text(phaseTitle(item.phase)).foregroundStyle(phaseColor(item.phase))
                    Text(item.event.title).font(.system(size: fullscreen ? 42 : 25, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(item.event.timeText + "   " + item.event.timezone).foregroundStyle(.secondary)
                    if !item.event.room.isEmpty {
                        Label {
                            LinkedText(text: item.event.room)
                        } icon: {
                            Image(systemName: "door.left.hand.open")
                        }.foregroundStyle(.secondary)
                    }
                    let providers = Array(Set(item.event.calls.map(\.url).compactMap(CalendarEvent.videoProvider))).sorted()
                    if !providers.isEmpty { Label(providers.joined(separator: " / "), systemImage: "video").foregroundStyle(.secondary) }
                    if item.phase == .end { Text("Запись продолжается.").foregroundStyle(.secondary) }
                    if item.phase != .end, model.isRecording, model.activeMeeting?.calendarEvent?.id != item.event.id {
                        Text("Текущая запись сохранится, затем начнётся новая.").font(.caption).foregroundStyle(.secondary)
                    }
                    if item.event.calls.count > 1 {
                        Picker("Видеовстреча", selection: $selectedURL) {
                            Text(item.event.calls.first?.label ?? "Выбери ссылку").tag(URL?.none)
                            ForEach(item.event.calls) { Text($0.label).tag(Optional($0.url)) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, items.count > 1 ? 38 : 0)
                .overlay(alignment: .leading) {
                    if items.count > 1 { pagingButton(forward: false) }
                }
                .overlay(alignment: .trailing) {
                    if items.count > 1 { pagingButton(forward: true) }
                }
            }
            if primary {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    if let item = selected, item.phase != .end {
                        let url = selectedURL ?? item.event.calls.first?.url
                        GridRow {
                            actionButton("Открыть встречу", action: .open, item: item)
                            actionButton("Записать", action: .record, item: item, url: url)
                                .disabled(!model.canRecordMeeting(item.event))
                        }
                        GridRow {
                            actionButton("Подключиться", action: .join, item: item, url: url)
                                .disabled(url == nil)
                            actionButton("Подключиться и записать", action: .joinAndRecord, item: item, url: url, prominent: true)
                                .disabled(!model.canRecordMeeting(item.event, openingVideo: url != nil) || url == nil)
                        }
                        GridRow {
                            actionButton("Через \(model.calendar.settings.snoozeMinutes) мин", action: .snooze, item: item)
                            actionButton("Закрыть", action: .dismiss, item: item)
                        }
                    } else if let item = selected {
                        GridRow {
                            actionButton("Остановить", action: .stop, item: item)
                            actionButton("Остановить и расшифровать", action: .stopAndTranscribe, item: item, prominent: true, tint: .red)
                        }
                    }
                }.controlSize(fullscreen ? .large : .regular)
            }
        }
        .padding(fullscreen ? 48 : 26)
        .frame(maxWidth: fullscreen ? 760 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onChange(of: selectedID) { _, _ in selectedURL = nil }
        .task(id: selected?.event.id) {
            if !preview, let event = selected?.event { _ = await model.calendar.loadDetail(event) }
        }
    }

    private func pagingButton(forward: Bool) -> some View {
        Button { moveSelection(forward ? 1 : -1) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28).frame(maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!primary)
            .accessibilityLabel(forward ? "Следующая встреча" : "Предыдущая встреча")
            .help(forward ? "Следующая встреча" : "Предыдущая встреча")
    }

    @ViewBuilder
    private func actionButton(_ title: String, action kind: ReminderAction, item: MeetingReminder?, url: URL? = nil,
                              prominent: Bool = false, tint: Color = .accentColor) -> some View {
        let button = Button { action(kind, item, url) } label: {
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: fullscreen ? 28 : 22)
        }
        if prominent { button.buttonStyle(.borderedProminent).tint(tint) }
        else { button.buttonStyle(.bordered) }
    }

    private func phaseTitle(_ phase: ReminderPhase) -> String {
        switch phase {
        case .soon: "Встреча скоро начнётся"
        case .start: "Встреча начинается"
        case .end: "Плановое время закончилось"
        }
    }

    private func phaseColor(_ phase: ReminderPhase) -> Color {
        switch phase {
        case .soon: .orange
        case .start: .blue
        case .end: .red
        }
    }

}
