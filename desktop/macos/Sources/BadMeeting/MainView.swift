import AppKit
import CoreAudio
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var calendarPopover = false
    @State private var deleteTarget: Meeting?
    @State private var linkTarget: Meeting?
    @State private var dropEventID: String?
    private var currentMeetingButton: some View {
        Button { model.openCurrentMeeting() } label: {
            Image(systemName: "asterisk").fontWeight(.bold)
        }
        .accessibilityLabel("Текущая встреча")
    }
    private func recordingTitle(_ recording: Meeting, index: Int, total: Int) -> String {
        "\(total - index). " + recording.createdAt.meetingFormatted(date: .omitted, time: .standard) + " — " + recording.sourceName + ", " + durationString(recording.duration)
    }
    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let event = model.selectedEvent {
                    EventDetailView(model: model, event: event)
                    let recordings = model.meetings.filter { $0.calendarEvent?.id == event.id }
                    if !recordings.isEmpty {
                        Picker("Записи встречи (\(recordings.count))", selection: $model.selectedMeetingID) {
                            ForEach(Array(recordings.enumerated()), id: \.element.id) { index, recording in
                                Text(recordingTitle(recording, index: index, total: recordings.count)).tag(Optional(recording.id))
                            }
                        }
                    }
                    Divider()
                }
                if let recording = model.selectedMeeting {
                    RecordingDetailView(model: model, recording: recording, delete: { deleteTarget = recording }, link: { linkTarget = recording })
                        .id(recording.id)
                } else if model.selectedEvent == nil {
                    ContentUnavailableView("Встречи и записи", systemImage: "waveform")
                        .frame(maxWidth: .infinity, minHeight: 400)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let event = model.selectedEvent {
                Text(event.title).font(.system(size: 23, weight: .semibold))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 6)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 1000 {
                    CalendarSidebar(model: model).frame(width: 210)
                    Divider()
                }
                VStack(spacing: 0) {
                    HStack {
                        Text(model.showingAllRecordings ? "Все записи" : model.selectedDate.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU")))).font(.headline)
                        Spacer()
                        if !model.showingAllRecordings {
                            Button { model.moveDay(-1) } label: { Image(systemName: "chevron.left") }
                                .help("Предыдущий день со встречами или записями")
                                .disabled(model.calendar.adjacentDay(to: model.selectedDate, direction: -1) == nil)
                            Button { model.moveDay(1) } label: { Image(systemName: "chevron.right") }
                                .help("Следующий день со встречами или записями")
                                .disabled(model.calendar.adjacentDay(to: model.selectedDate, direction: 1) == nil)
                        }
                        if geometry.size.width < 1000 {
                            Button { calendarPopover.toggle() } label: { Image(systemName: "calendar") }
                                .popover(isPresented: $calendarPopover) { CalendarSidebar(model: model).frame(width: 230, height: 500) }
                        }
                        currentMeetingButton
                    }.padding(16)
                    Divider()
                    agenda
                    if let error = model.calendar.errorMessage {
                        HStack(spacing: 6) {
                            Text("Календарь недоступен")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button {
                                Task { await model.calendar.refresh(userInitiated: true) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("Повторить подключение к календарю")
                            .help(error)
                            .disabled(!model.calendar.settings.anyCalendarEnabled)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.07))
                    }
                    Divider()
                    sourcePicker.padding(10)
                }.frame(width: 270).background(SidebarBackground())
                Divider()
                detailPane
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 580)
        .toolbar {
            ToolbarItem(id: "recording-indicator", placement: .principal) {
                if model.isRecording { RecordingIndicator(model: model) }
            }
            ToolbarItem(id: "recording-spacer", placement: .automatic) { Spacer() }
            ToolbarItem(id: "recording-control", placement: .confirmationAction) {
                Button {
                    if model.isRecording || model.isJoining { model.stopRecording() }
                    else { Task { await model.recordCurrentMeeting() } }
                } label: {
                    TimelineView(.animation(minimumInterval: 0.25, paused: !model.isRecording)) { context in
                        HStack(spacing: 8) {
                            Text("REC").font(.system(size: 12, weight: .bold))
                                .opacity(!model.isRecording || Int(context.date.timeIntervalSince1970 * 4) % 2 == 0 ? 1 : 0)
                            Image(systemName: model.isRecording ? "stop.fill" : model.isJoining ? "xmark" : "record.circle")
                                .frame(width: 16)
                        }
                        .frame(width: 76, height: 28)
                        .foregroundStyle(model.isRecording ? Color.red : Color.primary)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.isRecording ? Color.red : Color.clear, lineWidth: 1))
                    }
                }
                .accessibilityLabel(model.isRecording ? "Остановить запись" : model.isJoining ? "Отменить ожидание" : "Начать запись")
                .buttonStyle(.plain)
                .disabled(!model.isRecording && !model.isJoining && !model.canStartRecording)
            }
        }
        .alert("Встреча уже закончилась", isPresented: Binding(
            get: { model.endedMeetingRecordingRequest != nil },
            set: { if !$0 { model.endedMeetingRecordingRequest = nil } }
        ), presenting: model.endedMeetingRecordingRequest) { event in
            Button("Записать без привязки") {
                Task { await model.resolveEndedMeetingRecording(event, linked: false) }
            }
            Button("Записать во встречу") {
                Task { await model.resolveEndedMeetingRecording(event, linked: true) }
            }
            Button("Отмена", role: .cancel) { model.endedMeetingRecordingRequest = nil }
        } message: { event in
            Text("Встреча \"\(event.title)\" уже закончилась.")
        }
        .alert("Привязать запись ко встрече?", isPresented: Binding(
            get: { model.recordingLinkRequest != nil },
            set: { if !$0 { model.recordingLinkRequest = nil } }
        ), presenting: model.recordingLinkRequest) { request in
            Button("Отмена", role: .cancel) { model.recordingLinkRequest = nil }
            Button("Привязать") { Task { await model.confirmRecordingLink(request) } }
        } message: { request in
            Text(request.message)
        }
        .sheet(item: $linkTarget) { recording in LinkRecordingView(model: model, recording: recording) }
        .confirmationDialog("Удалить запись и расшифровку?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Удалить", role: .destructive) { if let deleteTarget { model.delete(deleteTarget) }; deleteTarget = nil }
        }
    }

    private var agenda: some View {
        List {
            if model.showingAllRecordings {
                ForEach(model.meetings) { recordingButton($0) }
            } else {
                let events = model.calendar.events(on: model.selectedDate)
                ForEach(events) { event in
                    Button { model.selectEvent(event) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(event.timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                if events.contains(where: { event.overlaps($0) }) {
                                    Image(systemName: "rectangle.on.rectangle").help("Встречи пересекаются").accessibilityLabel("Встречи пересекаются")
                                }
                            }
                            Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            HStack(spacing: 7) {
                                if event.videoURLs.first != nil { Image(systemName: "video") }
                                Text(eventState(event)).font(.caption)
                                Spacer()
                                let count = model.meetings.filter { $0.calendarEvent?.id == event.id }.count
                                if count > 0 { Label("\(count)", systemImage: "waveform").font(.caption) }
                            }.foregroundStyle(event.end < Date() ? Color.secondary : .accentColor)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background((model.selectedEventID == event.id || dropEventID == event.id) ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5))
                        .dropDestination(for: RecordingTransfer.self) { items, _ in
                            model.requestRecordingLink(items, to: event)
                        } isTargeted: { targeted in
                            if targeted { dropEventID = event.id }
                            else if dropEventID == event.id { dropEventID = nil }
                        }
                }
                let visibleIDs = Set(model.calendar.visibleEvents.map(\.id))
                let standalone = model.meetings.filter { ($0.calendarEvent == nil || !visibleIDs.contains($0.calendarEvent!.id)) && model.calendar.displayCalendar.isDate($0.createdAt, inSameDayAs: model.selectedDate) }
                if !standalone.isEmpty {
                    Section(standalone.allSatisfy { $0.calendarEvent == nil } ? "Без встречи" : "Другие записи") { ForEach(standalone) { recordingButton($0) } }
                }
                if events.isEmpty && standalone.isEmpty {
                    Text("В этот день нет сохранённых встреч и записей").foregroundStyle(.secondary).padding(.vertical, 16)
                }
                if model.selectedDate < Date().addingTimeInterval(-Double(model.calendar.settings.historyDays) * 86400) {
                    Text("Показаны только сохранённые встречи.").font(.caption).foregroundStyle(.secondary)
                    Button("Загрузить этот день") { Task { await model.calendar.refresh(day: model.selectedDate, userInitiated: true) } }.disabled(!model.calendar.settings.anyCalendarEnabled)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .id(model.showingAllRecordings ? nil : model.calendar.displayCalendar.startOfDay(for: model.selectedDate))
    }

    private func recordingButton(_ recording: Meeting) -> some View {
        Button { model.selectRecording(recording.id) } label: {
            RecordingRow(model: model, recording: recording).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.selectedMeetingID == recording.id ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5))
            .draggable(RecordingTransfer(id: recording.id))
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button { model.showSettingsWindow?() } label: { Image(systemName: "gearshape") }
                    .help("Настройки").accessibilityLabel("Настройки")
                ApplicationSourcePicker(model: model)
                .frame(minWidth: 90, maxWidth: .infinity).disabled(model.recordingBusy)
                .help(model.selectedSourceID == 0 ? "Записывается только микрофон" : "Записывается всё выбранное приложение, включая все вкладки браузера")
                Toggle(isOn: $model.microphoneEnabled) {
                    Image(systemName: model.microphoneEnabled ? "mic.fill" : "mic.slash")
                }.toggleStyle(.checkbox).fixedSize().disabled(model.recordingBusy)
                    .help("Записывать мой микрофон").accessibilityLabel("Записывать микрофон")
                Button { model.refreshSources() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить приложения").disabled(model.recordingBusy)
            }.controlSize(.small)
            if model.isJoining, let notice = model.sourceNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func eventState(_ event: CalendarEvent) -> String {
        if event.cancelled { return "Отменена" }
        if model.activeMeeting?.calendarEvent?.id == event.id { return "Идёт запись" }
        if event.start <= Date(), event.end > Date() { return "Сейчас" }
        if event.end <= Date() { return "Завершилась" }
        return model.calendar.displayCalendar.isDateInToday(event.start) ? "Сегодня" : "Запланирована"
    }
}

struct ApplicationSourcePicker: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        context.coordinator.button = button
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectSource)
        button.menu?.delegate = context.coordinator
        button.menu?.autoenablesItems = false
        context.coordinator.render()
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.render()
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        weak var model: AppModel?
        weak var button: NSPopUpButton?

        init(model: AppModel) {
            self.model = model
        }

        func menuWillOpen(_ menu: NSMenu) {
            model?.refreshSources()
            render()
        }

        @objc func selectSource() {
            guard let button, let selectedItem = button.selectedItem, selectedItem.tag >= 0 else { return }
            model?.selectRecordingSource(AudioObjectID(selectedItem.tag))
        }

        func render() {
            guard let model, let button else { return }
            button.removeAllItems()
            if model.microphoneEnabled {
                button.addItem(withTitle: "[Только микрофон]")
                button.lastItem?.tag = 0
            } else if model.selectedSourceID == 0 {
                button.addItem(withTitle: "Нет приложений")
                button.lastItem?.tag = 0
            }
            for source in model.sources {
                button.addItem(withTitle: source.name)
                button.lastItem?.tag = Int(source.id)
            }
            if let application = model.selectedMeetingApplication, model.selectedSourceID == 0 {
                button.addItem(withTitle: application.name + " *")
                button.lastItem?.tag = -1
                button.lastItem?.isEnabled = false
                button.selectItem(withTag: -1)
            } else {
                button.selectItem(withTag: Int(model.selectedSourceID))
            }
            button.isEnabled = !model.recordingBusy
        }
    }
}

private struct CalendarSidebar: View {
    @ObservedObject var model: AppModel
    @State private var month = Date()
    private var calendar: Calendar { model.calendar.displayCalendar }
    private var days: [Date?] {
        let start = calendar.dateInterval(of: .month, for: month)!.start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: offset) + calendar.range(of: .day, in: .month, for: month)!.map { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { model.showingAllRecordings = false } label: { Label("Календарь", systemImage: "calendar") }.buttonStyle(.plain).font(.headline)
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "ru_RU")))).font(.subheadline.bold())
                Spacer()
                Button { month = calendar.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }.help("Предыдущий месяц")
                Button { month = calendar.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }.help("Следующий месяц")
            }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 5) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(days.indices, id: \.self) { index in
                    if let day = days[index] { dayCell(day) } else { Color.clear.frame(height: 34) }
                }
            }
            Button("Сегодня") {
                let today = Date()
                month = today
                model.selectDay(today)
            }
            Divider()
            Button { model.showingAllRecordings = true } label: { Label("Все записи (\(model.meetings.count))", systemImage: "waveform") }.buttonStyle(.plain)
            Spacer()
            if model.calendar.syncing { ProgressView("Обновляется календарь").controlSize(.small) }
            else if let date = model.calendar.cache.lastSync { Text("Обновлено \(date.meetingFormatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            if !model.calendar.settings.anyCalendarEnabled {
                Button("Подключить календарь") { model.showSettingsWindow?() }.buttonStyle(.plain)
            }
        }
        .padding(14).background(SidebarBackground())
        .onChange(of: model.selectedDate) { _, date in month = date }
    }
    private func dayCell(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: model.selectedDate) && !model.showingAllRecordings
        let count = model.meetings.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }.count
        let events = model.calendar.events(on: day).count
        return Button {
            model.selectedDate = day; model.showingAllRecordings = false
            model.selectedEventID = nil; model.selectedMeetingID = nil
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))").font(.system(size: 12, weight: selected ? .bold : .regular))
                HStack(spacing: 2) {
                    if events > 0 { Circle().frame(width: 3, height: 3) }
                    if count > 0 { Text("\(count)").font(.system(size: 8, weight: .bold)) }
                }.frame(height: 9)
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            .foregroundStyle(selected ? .white : Color.primary)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(calendar.isDateInToday(day) ? Color.accentColor : .clear))
        }.buttonStyle(.plain).help("\(day.meetingFormatted(date: .complete, time: .omitted)): встреч \(events), записей \(count)")
    }
}

struct RecordingRow: View {
    @ObservedObject var model: AppModel
    let recording: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: recording.status == .recording ? "record.circle.fill" : "waveform").foregroundStyle(recording.status == .recording ? .red : Color.secondary)
                Text(recording.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
            }
            Text(recording.createdAt.meetingFormatted(date: .omitted, time: .shortened) + "  " + recording.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(model.transcribingIDs.contains(recording.id) ? "Расшифровывается" : recording.status == .recording ? "Идёт запись" : recording.transcript != nil ? "Расшифрована" : "Аудиозапись").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RecordingIndicator: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var samples = Array(repeating: Float(0), count: 20)
    @State private var visible = true
    @State private var lastSample = Date.distantPast
    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !visible)) { context in
            Button {
                if let id = model.recordingID { model.selectRecording(id) }
            } label: {
                HStack(spacing: 9) {
                    Circle().fill(.red).frame(width: 7, height: 7).opacity(reduceMotion ? 1 : (Int(context.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.4))
                    HStack(spacing: 2) {
                        ForEach(samples.indices, id: \.self) { index in
                            Capsule().fill(.red).frame(width: 2, height: 2 + CGFloat(context.date.timeIntervalSince(lastSample) > 0.8 ? 0 : samples[index]) * 20)
                        }
                    }.frame(height: 24)
                    Text("Идёт запись").font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize * 1.44))
                    Text(durationString(context.date.timeIntervalSince(model.activeMeeting?.createdAt ?? context.date))).monospacedDigit().font(.caption)
                }
                .foregroundStyle(.red)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: samples)
            }.buttonStyle(.plain).help(model.sourceNotice ?? "Открыть текущую запись")
        }
        .onReceive(model.meter.$level) { level in if visible { lastSample = Date(); samples.removeFirst(); samples.append(level) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            visible = NSApp.windows.contains { $0.title == "Bad Meeting" && $0.occlusionState.contains(.visible) }
        }
        .onDisappear { visible = false }
        .onAppear { visible = true }
    }
}

func durationString(_ duration: TimeInterval) -> String {
    let value = max(0, Int(duration))
    return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
}
