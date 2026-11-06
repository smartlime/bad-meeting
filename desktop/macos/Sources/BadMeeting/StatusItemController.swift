import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let openWindow: () -> Void
    private let item: NSStatusItem
    private var subscription: AnyCancellable?
    private var menuActions: [UUID: () -> Void] = [:]
    private let recordingBadge = MenuRecordingBadge()

    init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if let button = item.button {
            let cassette = menuImage(named: "Cassette")
            cassette?.isTemplate = true
            button.image = cassette
            recordingBadge.image = menuImage(named: "RecordingBadge")
            recordingBadge.isHidden = true
            recordingBadge.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(recordingBadge)
            NSLayoutConstraint.activate([
                recordingBadge.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                recordingBadge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                recordingBadge.widthAnchor.constraint(equalToConstant: 18),
                recordingBadge.heightAnchor.constraint(equalToConstant: 18)
            ])
        }
        subscription = model.$recordingID.sink { [weak self] recordingID in self?.updateIcon(isRecording: recordingID != nil) }
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp, let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(buildMenu(), with: event, for: button)
        } else { openWindow() }
    }

    private func command(_ title: String, in menu: NSMenu, enabled: Bool = true, action: @escaping () -> Void) {
        let id = UUID()
        menuActions[id] = action
        let item = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.isEnabled = enabled
        menu.addItem(item)
    }
    private func label(_ title: String, in menu: NSMenu) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
    @objc private func runCommand(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { menuActions[id]?() } }

    private func buildMenu() -> NSMenu {
        menuActions.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        command("Открыть окно", in: menu) { [self] in openWindow() }
        if let active = model.activeMeeting {
            label("Идёт запись: \(active.title)", in: menu)
            command("Остановить запись", in: menu) { [self] in model.stopRecording() }
            command("Остановить и расшифровать", in: menu) { [self] in model.stopAndTranscribe() }
        } else {
            command("Начать запись без встречи", in: menu, enabled: model.canStartRecording) { [self] in Task { await model.startRecording() } }
        }
        menu.addItem(.separator())
        label("Сегодня, \(Date().formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU"))))", in: menu)
        let events = model.calendar.events(on: Date())
        let now = Date()
        let groups: [(String, [CalendarEvent])] = [
            ("Сейчас", events.filter { $0.start <= now && $0.end > now }),
            ("Позже", events.filter { $0.start > now }),
            ("Ранее сегодня", events.filter { $0.end <= now })
        ]
        for (title, events) in groups where !events.isEmpty {
            label(title, in: menu)
            for event in events {
                let row = NSMenuItem(title: "\(event.timeText)   \(event.title)", action: nil, keyEquivalent: "")
                row.submenu = eventMenu(event)
                menu.addItem(row)
            }
        }
        if events.isEmpty { label(model.calendar.settings.connected ? "На сегодня нет сохранённых встреч" : "Календарь не подключён", in: menu) }
        command("Открыть сегодняшний день", in: menu) { [self] in
            model.selectedDate = Date(); model.showingAllRecordings = false; model.selectedEventID = nil; model.selectedMeetingID = nil; openWindow()
        }
        if model.calendar.errorMessage != nil {
            label("Расписание не обновлено", in: menu)
            if let date = model.calendar.cache.lastSync { label("Последнее обновление: \(date.meetingFormatted(date: .abbreviated, time: .shortened))", in: menu) }
        }
        menu.addItem(.separator())
        command("Настройки…", in: menu) { [self] in model.showSettingsWindow?() }
        command("Завершить приложение", in: menu) { NSApp.terminate(nil) }
        return menu
    }

    private func eventMenu(_ event: CalendarEvent) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let urls = event.calls.map(\.url)
        if urls.isEmpty {
            label("Видеоссылка не указана", in: menu)
            command("Записать встречу", in: menu, enabled: model.canRecordMeeting(event)) { [self] in Task { await model.recordMeeting(event) } }
        } else {
            for url in urls {
                let title = urls.count == 1 ? "Подключиться к видео" : "\(CalendarEvent.videoProvider(url) ?? "Видео"): \(url.lastPathComponent)"
                command(title, in: menu) { [self] in model.join(event, url: url, record: false) }
                command("Подключиться и записать", in: menu, enabled: model.canRecordMeeting(event, openingVideo: true)) { [self] in model.join(event, url: url, record: true) }
            }
        }
        menu.addItem(.separator())
        label(event.timeText + "  " + event.timezone, in: menu)
        if event.cancelled { label("Встреча отменена", in: menu) }
        if let organizer = event.organizer { label("Организатор: \(organizer.displayName)", in: menu) }
        if !event.room.isEmpty { label("Переговорная: \(event.room)", in: menu) }
        label("Приглашены: \(event.attendees.count), приняли: \(event.attendees.filter { $0.decision == "yes" }.count)", in: menu)
        label("Записей: \(model.meetings.filter { $0.calendarEvent?.id == event.id }.count)", in: menu)
        command("Открыть встречу и записи", in: menu) { [self] in model.selectedDate = event.start; model.showingAllRecordings = false; model.selectEvent(event); openWindow() }
        menu.addItem(.separator())
        command(event.calendarURL == nil ? "Ссылка на встречу в календаре не получена" : "Открыть встречу в Яндекс Календаре", in: menu, enabled: event.calendarURL != nil) { [self] in if let url = event.calendarURL { _ = model.openURL(url) } }
        return menu
    }

    private func updateIcon(isRecording: Bool) {
        recordingBadge.setRecording(isRecording)
        item.button?.toolTip = isRecording ? "Bad Meeting: идёт запись" : "Bad Meeting"
    }

    private func menuImage(named name: String) -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for suffix in ["", "@2x"] {
            guard let url = Bundle.module.url(forResource: name + suffix, withExtension: "png", subdirectory: "MenuBar"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = image.size
            image.addRepresentation(representation)
        }
        return image.representations.isEmpty ? nil : image
    }
}
