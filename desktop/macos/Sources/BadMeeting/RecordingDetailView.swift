import AppKit
import AVFAudio
import Foundation
import SwiftUI

struct EventDetailView: View {
    @ObservedObject var model: AppModel
    let event: CalendarEvent
    private var url: URL? {
        if model.selectedEventID == event.id, let selected = model.selectedMeetingURL,
           event.calls.contains(where: { $0.url == selected }) { return selected }
        return event.calls.first?.url
    }
    private var recordings: [Meeting] { model.meetings.filter { $0.calendarEvent?.id == event.id } }
    private var recordingsDuration: TimeInterval { recordings.reduce(0) { $0 + $1.duration } }
    private var recordingsSize: Int64 { recordings.reduce(0) { $0 + model.storageSize(for: $1) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label(event.timeText + "  " + event.timezone, systemImage: "clock")
                if event.cancelled { Label("Встреча отменена", systemImage: "xmark.circle").foregroundStyle(.red) }
                if !event.room.isEmpty {
                    Label {
                        LinkedText(text: event.room)
                    } icon: {
                        Image(systemName: "door.left.hand.open")
                    }
                }
                ForEach(event.calls) { call in
                    HStack(spacing: 12) {
                        MeetingHeaderLink(url: call.url, title: call.label, systemImage: "video")
                        if let password = call.password {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(password, forType: .string)
                            } label: {
                                Text(password).font(.system(size: 13, design: .monospaced))
                                    .padding(.horizontal, 6).frame(height: 20)
                                    .background {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.secondary.opacity(0.12)).padding(.vertical, -1)
                                    }
                            }.buttonStyle(.plain).accessibilityLabel("Скопировать пароль " + password)
                        }
                    }
                }
                if let link = event.calendarURL {
                    MeetingHeaderLink(url: link, title: "Встреча в календаре", systemImage: "calendar")
                }
                if !recordings.isEmpty {
                    HStack(spacing: 16) {
                        Label("Записи: \(durationString(recordingsDuration))", systemImage: "clock")
                        Label("Файлы: \(ByteCountFormatter.string(fromByteCount: recordingsSize, countStyle: .file))", systemImage: "internaldrive")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let organizer = event.organizer { Label(organizer.displayName, systemImage: "person.crop.circle.badge.checkmark").help("Организатор: \(organizer.email)") }
            }.font(.system(size: 13)).labelStyle(MeetingMetadataLabelStyle())
            if !event.attendees.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Приглашены (\(event.attendees.count))").font(.caption).foregroundStyle(.secondary)
                    MeetingAttendeesView(attendees: event.attendees, previewCount: model.attendeesPreviewCount).id(event.id)
                }
            }
            if !event.description.isEmpty {
                MeetingDescriptionView(text: event.description, previewLines: model.descriptionPreviewLines).id(event.id)
            }
            if event.calls.count > 1 {
                Picker("Видеовстреча", selection: Binding(get: { url }, set: { model.selectMeetingLink(event, url: $0) })) {
                    ForEach(event.calls) { Text($0.label).tag(Optional($0.url)) }
                }
            }
            HStack {
                Button("Подключиться", systemImage: "video") {
                    if let url { model.join(event, url: url, record: false) }
                }.disabled(url == nil)
                Button("Записать", systemImage: "record.circle") { Task { await model.recordMeeting(event, url: url) } }
                    .disabled(!model.canRecordMeeting(event) || model.isJoining)
                Button("Подключиться и записать") {
                    if let url { model.join(event, url: url, record: true) }
                }.buttonStyle(.borderedProminent)
                    .disabled(url == nil || !model.canRecordMeeting(event, openingVideo: true) || model.isJoining)
                Spacer()
            }.controlSize(.small)
            if model.isRecording, model.activeMeeting?.calendarEvent?.id != event.id {
                Text("Текущая запись сохранится, затем начнётся новая.").font(.caption).foregroundStyle(.secondary)
            }
            if event.calls.isEmpty { Text("Видеоссылка не указана").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct MeetingMetadataLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.icon.frame(width: 18, height: 20)
            configuration.title.frame(minHeight: 20, alignment: .leading)
        }
    }
}

struct MeetingAttendeesView: View {
    let attendees: [CalendarPerson]
    var previewCount: Int = 9
    @State private var width: CGFloat = 0
    @State private var expanded = false

    static func columns(width: CGFloat) -> Int {
        min(3, max(1, Int((width + 12) / 162)))
    }

    static func visibleCount(total: Int, limit: Int, expanded: Bool) -> Int {
        expanded ? total : min(total, max(1, limit))
    }

    static func moreLabel(_ count: Int) -> String {
        let word: String
        if (11...14).contains(count % 100) {
            word = "участников"
        } else {
            switch count % 10 {
            case 1: word = "участник"
            case 2...4: word = "участника"
            default: word = "участников"
            }
        }
        return "Еще \(count) \(word)"
    }

    private var columns: Int { Self.columns(width: width) }
    private var visibleCount: Int { Self.visibleCount(total: attendees.count, limit: previewCount, expanded: expanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: columns), alignment: .leading, spacing: 10) {
                ForEach(attendees.prefix(visibleCount)) { person in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: person.responseSymbol)
                            .font(.system(size: 11))
                            .foregroundStyle(person.decision == "yes" ? Color.green : .secondary)
                            .frame(width: 13, height: 16)
                        Text(person.displayName)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.help("\(person.displayName)\n\(person.email)\n\(person.responseLabel)").accessibilityLabel("\(person.displayName), \(person.responseLabel)")
                }
            }
            if visibleCount < attendees.count {
                ExpansionControl(title: Self.moreLabel(attendees.count - visibleCount), expanded: false) { expanded = true }
            } else if expanded && attendees.count > max(1, previewCount) {
                ExpansionControl(title: "Свернуть участников", expanded: true) { expanded = false }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct MeetingDescriptionView: View {
    let text: String
    let previewLines: Int
    @State private var expanded = false
    @State private var shortCollapsed = false
    @State private var previewHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > previewHeight + 0.5 }
    private var fullyExpanded: Bool { overflows ? expanded : !shortCollapsed }

    private func toggle() {
        if overflows { expanded.toggle() } else { shortCollapsed.toggle() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExpansionControl(title: "Описание", expanded: fullyExpanded, action: toggle)
            if overflows || !shortCollapsed {
                LinkedText(text: text, fontSize: 12, lineSpacing: 2, lineLimit: fullyExpanded ? nil : max(1, previewLines))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if overflows {
                ExpansionControl(title: expanded ? "Свернуть описание" : "Показать описание полностью", expanded: expanded, action: toggle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinkedText(text: text, fontSize: 12, lineSpacing: 2, lineLimit: max(1, previewLines))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                .hidden()
        }
        .background {
            LinkedText(text: text, fontSize: 12, lineSpacing: 2)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .hidden()
        }
    }
}

func linkedDescription(_ text: String) -> AttributedString {
    var result = AttributedString(text)
    for match in CalendarParser.links(text) {
        if let range = Range(match.range, in: text), let attributedRange = Range(range, in: result), let url = match.url {
            result[attributedRange].link = url
        }
    }
    return result
}

struct RecordingDetailView: View {
    @ObservedObject var model: AppModel
    let recording: Meeting
    let delete: () -> Void
    let link: () -> Void
    @State private var title = ""
    @StateObject private var player = RecordingPlayer()
    @State private var speakers: [String] = []
    @State private var turns: [TranscriptTurn] = []
    @State private var displayedTurns = 50
    private var duration: Double { recording.duration }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Название записи", text: $title)
                .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                .onSubmit { model.updateRecording(recording.id, title: title, event: nil, changeLink: false) }
            HStack(alignment: .top) {
                Label(recording.calendarEvent == nil ? "Без события в календаре" : "Связана со встречей", systemImage: recording.calendarEvent == nil ? "waveform" : "link")
                    .font(.caption).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .draggable(RecordingTransfer(id: recording.id))
                    .help("Привязать перетаскиванием на встречу")
                Spacer()
                HStack(spacing: 8) {
                    Button(recording.calendarEvent == nil ? "Привязать к встрече" : "Изменить встречу", action: link)
                    if recording.calendarEvent != nil { Button("Снять привязку") { model.updateRecording(recording.id, event: nil) } }
                }.fixedSize()
            }
            if let notice = model.sourceNotice, recording.id == model.recordingID { Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 16) {
                Label(recording.sourceName, systemImage: "mic").lineLimit(2)
                Text(durationString(duration)).monospacedDigit()
                Text(recording.createdAt.meetingFormatted(date: .abbreviated, time: .shortened))
            }.font(.caption).foregroundStyle(.secondary)
            if recording.status != .recording, !recording.segments.isEmpty {
                HStack {
                    Button {
                        guard let path = model.storagePath(for: recording) else { return }
                        player.toggle(recording: recording, directory: URL(fileURLWithPath: path), failure: { model.report($0, context: "Не удалось воспроизвести запись") })
                    } label: { Label(player.playing ? "Пауза" : "Слушать", systemImage: player.playing ? "pause.fill" : "play.fill") }.disabled(player.loading)
                    if player.loading { ProgressView().controlSize(.small) }
                    if player.loaded {
                        Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration)).accessibilityLabel("Позиция воспроизведения")
                        Text(durationString(player.position)).monospacedDigit().font(.caption)
                    }
                }
            }
            HStack {
                Button(recording.transcript == nil ? "Расшифровать" : "Расшифровать заново") { model.transcribe(recording) }
                    .disabled(recording.status == .recording || recording.segments.isEmpty || model.transcribingIDs.contains(recording.id) || model.namingSpeakerIDs.contains(recording.id))
                if recording.transcript != nil { Button("Скопировать текст", systemImage: "doc.on.doc") { model.copyTranscript(recording) } }
                Spacer()
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }.disabled(recording.status == .recording || model.transcribingIDs.contains(recording.id) || model.namingSpeakerIDs.contains(recording.id)).help("Удалить запись")
            }
            DisclosureGroup("Сведения о записи") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow { Text("Начало").foregroundStyle(.secondary); Text(recording.createdAt.meetingFormatted(date: .complete, time: .standard)) }
                    GridRow { Text("Окончание").foregroundStyle(.secondary); Text(recording.endedAt?.meetingFormatted(date: .abbreviated, time: .standard) ?? (recording.status == .recording ? "Запись продолжается" : "Время не сохранено")) }
                    GridRow { Text("Состояние").foregroundStyle(.secondary); Text(recording.status == .interrupted ? "Прервалась, сохранённое аудио доступно" : recording.status == .ready ? "Завершена" : "Идёт запись") }
                    if let provider = recording.transcript?.transcriptionProvider,
                       let transcriptionModel = TranscriptionModel(rawValue: provider) {
                        GridRow { Text("Распознавание").foregroundStyle(.secondary); Text(transcriptionModel.title) }
                    }
                    GridRow { Text("Аудиосегменты").foregroundStyle(.secondary); Text("\(recording.segments.count)") }
                    GridRow { Text("Идентификатор").foregroundStyle(.secondary); Text(recording.id.uuidString).textSelection(.enabled) }
                    if let path = model.storagePath(for: recording) {
                        GridRow { Text("Папка").foregroundStyle(.secondary); Button("Показать в Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } }
                    }
                    ForEach(Array((recording.sourceChanges ?? []).enumerated()), id: \.offset) { _, change in
                        GridRow { Text(change.at.meetingFormatted(date: .omitted, time: .standard)); Text(change.name) }
                    }
                }.font(.caption).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let snapshot = recording.calendarEvent {
                DisclosureGroup("Снимок встречи при привязке записи") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.title).font(.headline)
                        Text(snapshot.timeText + "  " + snapshot.timezone)
                        if let organizer = snapshot.organizer { Text("Организатор: " + organizer.displayName) }
                        if !snapshot.room.isEmpty {
                            HStack(spacing: 4) {
                                Text("Переговорная:")
                                LinkedText(text: snapshot.room, fontSize: 11)
                            }
                        }
                        ForEach(snapshot.attendees) { person in Text(person.displayName + " — " + person.responseLabel) }
                        if !snapshot.description.isEmpty { LinkedText(text: snapshot.description, fontSize: 11) }
                    }.font(.caption).textSelection(.enabled).padding(.top, 8)
                }
            }
            if recording.transcript != nil || recording.transcriptionError != nil || model.transcribingIDs.contains(recording.id) { Divider() }
            if model.transcribingIDs.contains(recording.id) { ProgressView("Идёт расшифровка") }
            else if let error = recording.transcriptionError {
                HStack {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Повторить") { model.transcribe(recording) }
                }
            }
            if let progress = model.transcriptionProgress[recording.id] {
                Text(progress).font(.caption).foregroundStyle(.secondary)
            }
            if let transcript = recording.transcript {
                if !speakers.isEmpty {
                    DisclosureGroup("Имена спикеров") {
                        ForEach(speakers, id: \.self) { speaker in
                            HStack {
                                Text(speaker).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                TextField("Имя", text: Binding(get: { recording.transcript?.speakerNames[speaker] ?? "" }, set: { model.setSpeakerName($0, speakerID: speaker, meetingID: recording.id) }))
                                if let evidence = transcript.speakerEvidence?[speaker] {
                                    Image(systemName: "sparkles").foregroundStyle(.secondary).help("Имя определено по контексту:\n" + evidence)
                                }
                                if let attendees = recording.calendarEvent?.speakerCandidates, !attendees.isEmpty {
                                    Menu { ForEach(attendees) { person in Button(person.displayName) { model.setSpeakerName(person.displayName, speakerID: speaker, meetingID: recording.id) } } } label: { Image(systemName: "person.crop.circle") }
                                        .fixedSize().help("Выбрать участника или организатора")
                                }
                            }
                        }.padding(.top, 6)
                        Button("Определить имена по контексту") { model.identifySpeakerNames(recording) }
                            .disabled(model.transcriptionModel == .speechkit || !model.canIdentifySpeakers(transcript) || model.namingSpeakerIDs.contains(recording.id) || model.transcribingIDs.contains(recording.id))
                    }
                }
                if model.namingSpeakerIDs.contains(recording.id) { ProgressView("Определяются имена спикеров").controlSize(.small) }
                if let warning = transcript.speakerNamingWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                if let warning = transcript.wordWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(turns.prefix(displayedTurns)) { turn in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(transcript.speakerNames[turn.speakerID].flatMap { $0.isEmpty ? nil : $0 } ?? turn.speakerID).font(.headline)
                                Button(durationString(turn.start)) { player.seek(turn.start) }.buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary).disabled(!player.loaded)
                            }
                            Text(turn.text).textSelection(.enabled).lineSpacing(4)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if turns.count > displayedTurns {
                        Button("Показать следующие реплики (ещё \(turns.count - displayedTurns))") { displayedTurns += 50 }
                    }
                    if transcript.words.isEmpty { Text(transcript.text).textSelection(.enabled) }
                }
            }
        }
        .task(id: recording.transcript?.revision) {
            let words = recording.transcript?.words ?? []
            let presentation = await Task.detached(priority: .utility) {
                (TranscriptFormatter.turns(from: words), Array(Set(words.compactMap(\.speakerID))).sorted())
            }.value
            guard !Task.isCancelled else { return }
            turns = presentation.0
            speakers = presentation.1
            displayedTurns = 50
        }
        .onAppear { title = recording.title }
        .onDisappear { player.clear(); model.updateRecording(recording.id, title: title, event: nil, changeLink: false) }
    }
}

@MainActor
private final class RecordingPlayer: ObservableObject {
    @Published var playing = false
    @Published var loading = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var loaded = false
    private var audio: AVAudioPlayer?
    private var file: URL?
    private var timer: Timer?
    private var generation = UUID()

    func toggle(recording: Meeting, directory: URL, failure: @escaping (Error) -> Void) {
        if let audio {
            if playing { audio.pause(); playing = false; timer?.invalidate() } else { audio.play(); playing = true; tick() }
            return
        }
        guard !loading else { return }
        loading = true
        let current = generation
        Task {
            do {
                let url = try await Task.detached(priority: .utility) { try AudioAssembler.makeUploadFile(for: recording, in: directory) }.value
                guard generation == current else { try? FileManager.default.removeItem(at: url); return }
                file = url
                audio = try AVAudioPlayer(contentsOf: url)
                duration = audio?.duration ?? 0
                loaded = true
                playing = audio?.play() == true
                tick()
            } catch { failure(error); clear() }
            loading = false
        }
    }
    private func tick() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = self.audio?.currentTime ?? 0
                self.playing = self.audio?.isPlaying ?? false
                if !self.playing { self.timer?.invalidate() }
            }
        }
    }
    func seek(_ position: Double) { audio?.currentTime = min(max(0, position), duration); self.position = audio?.currentTime ?? 0 }
    func clear() {
        generation = UUID()
        audio?.stop(); audio = nil
        timer?.invalidate(); timer = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil; loading = false; playing = false; loaded = false
    }
}

struct LinkRecordingView: View {
    @ObservedObject var model: AppModel
    let recording: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var search = ""
    @State private var selectedID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Привязать запись к встрече").font(.title2)
            HStack {
                DatePicker("Дата", selection: $date, displayedComponents: .date)
                Button("Загрузить день") { Task { await model.calendar.refresh(day: date, userInitiated: true) } }.disabled(!model.calendar.settings.anyCalendarEnabled || model.calendar.syncing)
            }
            TextField("Название встречи", text: $search)
            let events = model.calendar.events(on: date).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.sorted { abs($0.start.timeIntervalSince(recording.createdAt)) < abs($1.start.timeIntervalSince(recording.createdAt)) }
            List(events, selection: $selectedID) { event in
                VStack(alignment: .leading) { Text(event.title); Text(event.timeText).font(.caption).foregroundStyle(.secondary) }.tag(event.id)
            }.frame(height: 240)
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Привязать") {
                    if let event = events.first(where: { $0.id == selectedID }) {
                        Task {
                            let snapshot = await model.calendar.loadDetail(event)
                            model.updateRecording(recording.id, event: snapshot)
                            dismiss()
                        }
                    }
                }.buttonStyle(.borderedProminent).disabled(selectedID == nil)
            }
        }.padding(24).frame(width: 560)
        .onAppear { date = recording.createdAt }
        .onChange(of: date) { _, _ in selectedID = nil }
    }
}

struct MeetingHeaderLink: View {
    let url: URL
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Link(destination: url) {
                Label(title, systemImage: systemImage)
                    .lineLimit(1).truncationMode(.middle)
            }.linkCursor().help(url.absoluteString)
            Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
                    .frame(width: 16, height: 20)
            }.fixedSize().foregroundStyle(.secondary).linkCursor()
                .help("Открыть ссылку").accessibilityLabel("Открыть ссылку")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 16, height: 20)
            }.buttonStyle(.plain).fixedSize().foregroundStyle(.secondary)
                .help("Скопировать ссылку").accessibilityLabel("Скопировать ссылку")
        }
    }
}
