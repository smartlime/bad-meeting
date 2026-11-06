import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case processing, calendars, reminders, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .processing: "Запись и обработка"
        case .calendars: "Календари"
        case .reminders: "Напоминания"
        case .advanced: "Дополнительно"
        }
    }
    var icon: String {
        switch self {
        case .processing: "waveform"
        case .calendars: "calendar"
        case .reminders: "bell"
        case .advanced: "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var height: CGFloat = 650
    var initialSection: SettingsSection = .processing
    var resolveCredentials = true
    @State private var section: SettingsSection = .processing

    private func setting<T>(_ path: WritableKeyPath<CalendarSettings, T>) -> Binding<T> {
        Binding(get: { model.calendar.settings[keyPath: path] }, set: { value in
            model.calendar.updateSettings { $0[keyPath: path] = value }
        })
    }

    private func minutes(_ path: WritableKeyPath<CalendarSettings, Int>) -> Binding<Int> {
        Binding(get: { model.calendar.settings[keyPath: path] }, set: { value in
            model.calendar.updateSettings { $0[keyPath: path] = min(60, max(1, value)) }
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Bad Meeting").font(.headline).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 14)
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .background(section == item ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }.padding(10).frame(width: 186).background(SidebarBackground())
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title).font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 20).frame(height: 48)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch section {
                        case .processing: processing
                        case .calendars: calendars
                        case .reminders: reminders
                        case .advanced: advanced
                        }
                    }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 18)
                }.id(section)
            }.frame(maxWidth: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.frame(width: 840, height: height)
            .controlSize(.small)
            .onAppear { section = initialSection }
    }

    private var processing: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Запись") {
                SettingsRow("Формат аудио") {
                    Picker("Формат аудио", selection: $model.audioStorageFormat) {
                        ForEach(AudioStorageFormat.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 240)
                }
            }
            SettingsGroup("Распознавание речи") {
                SettingsRow("Провайдер") {
                    Picker("Провайдер распознавания", selection: $model.transcriptionModel) {
                        ForEach(TranscriptionModel.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 240)
                }
                SettingsCredentialField(model: model, service: model.transcriptionModel.provider.credential, resolve: resolveCredentials)
                    .id(model.transcriptionModel)
                if model.transcriptionModel == .speechkit {
                    SettingsRow("Каталог AI Studio") {
                        TextField("Каталог AI Studio", text: $model.speechKitSettings.folderID).labelsHidden().frame(width: 240)
                    }
                    SettingsRow("Язык") {
                        Picker("Язык", selection: $model.speechKitSettings.language) {
                            Text("Автоматически").tag("")
                            Text("Русский").tag("ru-RU")
                            Text("Английский").tag("en-US")
                        }.labelsHidden().frame(width: 180)
                    }
                    SettingsRow("Различать двух говорящих") {
                        Toggle("Различать двух говорящих", isOn: $model.speechKitSettings.speakerLabeling).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow("Добавлять пунктуацию") {
                        Toggle("Добавлять пунктуацию", isOn: $model.speechKitSettings.literatureText).labelsHidden().toggleStyle(.switch)
                    }
                }
                if model.transcriptionModel.provider.usesElevenLabsSettings {
                    SettingsRow("Язык") {
                        Picker("Язык распознавания", selection: $model.elevenLabsSettings.language) {
                            Text("Автоматически").tag("")
                            Text("Русский").tag("rus")
                            Text("Английский").tag("eng")
                        }.labelsHidden().frame(width: 180)
                    }
                    SettingsRow("Различать говорящих") {
                        Toggle("Различать говорящих", isOn: $model.elevenLabsSettings.diarize).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            SettingsGroup("Текстовая модель") {
                SettingsRow("Провайдер") {
                    Picker("Провайдер текстовой модели", selection: $model.textSettings.providerID) {
                        ForEach(Edition.textProviders) { Text($0.title).tag($0.id) }
                    }.labelsHidden().frame(width: 240)
                }
                if let credential = model.textSettings.provider.credential {
                    SettingsCredentialField(model: model, service: credential, resolve: resolveCredentials).id(credential.rawValue)
                }
                if model.textSettings.provider.usesFolderID {
                    SettingsRow("Каталог AI Studio") {
                        TextField("Каталог AI Studio", text: $model.textConnection.folderID).labelsHidden().frame(width: 240)
                    }
                }
                if model.textSettings.provider.usesBaseURL {
                    SettingsRow("Адрес сервера") {
                        TextField("Адрес сервера", text: $model.textConnection.baseURL).labelsHidden().frame(width: 240)
                    }
                }
                SettingsRow("Модель") {
                    if model.textSettings.provider.models.isEmpty {
                        TextField("Модель", text: $model.textConnection.model).labelsHidden().frame(width: 240)
                    } else {
                        Picker("Текстовая модель", selection: $model.textConnection.model) {
                            ForEach(model.textSettings.provider.models, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 240)
                    }
                }
                SettingsRow("Определять имена после расшифровки") {
                    Toggle("Определять имена после расшифровки", isOn: $model.automaticSpeakerNaming)
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }.textFieldStyle(.roundedBorder)
    }

    private var calendars: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Edition.calendarSources) { source in
                SettingsGroup(source.title) {
                    SettingsRow("Подключить") {
                        Toggle("Подключить " + source.title, isOn: Binding(get: {
                            model.calendar.settings.connection(source).enabled
                        }, set: { enabled in
                            model.calendar.updateSettings { settings in
                                var connection = settings.connection(source)
                                connection.enabled = enabled
                                settings.setConnection(connection, for: source)
                            }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    if model.calendar.settings.connection(source).enabled {
                        if let service = source.credential {
                            SettingsCredentialField(model: model, service: service, resolve: resolveCredentials)
                        }
                        ForEach(model.calendar.layers(for: source)) { layer in
                            CalendarLayerToggle(model: model, source: source, layer: layer).padding(.vertical, 4)
                        }
                    }
                }
            }
            HStack {
                if let date = model.calendar.cache.lastSync {
                    Text(date.meetingFormatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Обновить") { Task { await model.calendar.refresh(userInitiated: true) } }
                    .disabled(model.calendar.syncing || !model.calendar.settings.anyCalendarEnabled)
            }
            if let error = model.calendar.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            SettingsGroup("Отображение и хранение") {
                SettingsRow("Часовой пояс") {
                    Picker("Часовой пояс", selection: setting(\.timezone)) {
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 240)
                }
                SettingsRow("История календаря") {
                    NumericSettingField(title: "Дней истории", value: setting(\.historyDays), range: 7...30)
                    Text("дней").foregroundStyle(.secondary)
                }
            }
        }.textFieldStyle(.roundedBorder)
    }

    private var reminders: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Встречи") {
                reminderRow("Напоминать заранее", enabled: setting(\.remindSoon), fullscreen: Binding(get: {
                    model.calendar.settings.fullscreen(for: .soon)
                }, set: { value in model.calendar.updateSettings { $0.fullscreenSoon = value } })) {
                    model.reminders.preview(soon: true)
                }
                HStack(spacing: 6) {
                    Text("За")
                    NumericSettingField(title: "Минут до начала", value: minutes(\.soonMinutes), range: 1...60)
                    Text("мин до начала")
                    Spacer()
                }.padding(.leading, 19).disabled(!model.calendar.settings.remindSoon)
                reminderRow("Напоминать о начале", enabled: setting(\.remindStart), fullscreen: setting(\.fullscreenStart)) {
                    model.reminders.preview(end: false)
                }
                reminderRow("Напоминать об окончании", enabled: setting(\.remindEnd), fullscreen: setting(\.fullscreenEnd)) {
                    model.reminders.preview(end: true)
                }
            }
            SettingsGroup("Повтор") {
                SettingsRow("Повторять через") {
                    NumericSettingField(title: "Минут до повтора", value: minutes(\.snoozeMinutes), range: 1...60)
                    Text("мин").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reminderRow(_ title: String, enabled: Binding<Bool>, fullscreen: Binding<Bool>, preview: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: enabled).toggleStyle(.checkbox)
            Spacer(minLength: 8)
            Picker("Показ: " + title, selection: fullscreen) {
                Text("В окне").tag(false)
                Text("На весь экран").tag(true)
            }.labelsHidden().frame(width: 122).disabled(!enabled.wrappedValue)
            Button("Показать пример", action: preview).disabled(!enabled.wrappedValue)
        }.padding(.vertical, 4).frame(minHeight: 30)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Сервисы") {
                SettingsRow("Использовать aiw") {
                    Toggle("Использовать aiw", isOn: $model.credentials.useAIW).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup("Отображение встречи") {
                SettingsRow("Строк описания") {
                    NumericSettingField(title: "Строк описания", value: $model.descriptionPreviewLines, range: 1...100)
                }
                SettingsRow("Участников сразу") {
                    NumericSettingField(title: "Участников сразу", value: $model.attendeesPreviewCount, range: 1...1000)
                }
            }
            SettingsGroup("Диагностика") {
                SettingsRow("Режим отладки") {
                    Toggle("Режим отладки", isOn: $model.debugMode).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0, content: content)
                .font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.system(size: 12, weight: .medium))
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            content()
        }.frame(minHeight: 30).padding(.vertical, 1)
    }
}

private struct SettingsCredentialField: View {
    @ObservedObject var model: AppModel
    let service: CredentialService
    let resolve: Bool
    @State private var value = ""
    @State private var name = ""
    @State private var mask = ""
    @State private var editing = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var identity: String {
        "\(model.credentials.useAIW)|\(model.credentials.keyName(for: service))|\(model.credentialRevision)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(model.credentials.useAIW ? "Ключ aiw" : "Ключ") {
                if model.credentials.useAIW {
                    TextField("Имя ключа", text: $name).labelsHidden().frame(width: 200)
                        .focused($nameFocused).onSubmit(commitName)
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    maskedValue
                } else if !mask.isEmpty && !editing {
                    maskedValue
                    Button("Заменить") { editing = true; error = nil }
                    Button("Удалить") { perform { try await model.deleteCredential(service); mask = ""; value = "" } }
                } else {
                    SecureField("Ключ", text: $value).labelsHidden().frame(width: 200)
                    if !mask.isEmpty { maskedValue }
                    Button("Сохранить") {
                        let input = value
                        perform {
                            try await model.saveCredential(input, for: service)
                            mask = CredentialSettings.masked(input)
                            value = ""
                            editing = false
                        }
                    }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editing { Button("Отмена") { value = ""; editing = false; error = nil } }
                }
                if busy { ProgressView().controlSize(.mini) }
            }.disabled(busy)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.textFieldStyle(.roundedBorder)
            .task(id: identity) { await refresh() }
            .onDisappear { value = "" }
    }

    private var maskedValue: some View {
        Text(mask).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .frame(minWidth: 68, alignment: .trailing).textSelection(.enabled)
            .accessibilityLabel("Сокращенный ключ").accessibilityValue(mask)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.credentials.keyName(for: service) else { return }
        model.credentials.aiwNames[service.rawValue] = trimmed
    }

    private func refresh() async {
        name = model.credentials.keyName(for: service)
        mask = ""
        error = nil
        value = ""
        editing = false
        guard resolve else { return }
        let snapshot = model.credentials
        do {
            try await Task.sleep(for: .milliseconds(200))
            let token: String
            if snapshot.useAIW {
                token = try await snapshot.token(for: service)
            } else {
                let legacy = snapshot.legacyToken(for: service)
                if !legacy.isEmpty { try await model.saveCredential(legacy, for: service) }
                token = try await Task.detached { try CredentialKeychain.read(service) }.value
            }
            guard !Task.isCancelled else { return }
            mask = CredentialSettings.masked(token)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct CalendarLayerToggle: View {
    @ObservedObject var model: AppModel
    let source: CalendarSource
    let layer: CalendarLayer
    var body: some View {
        Toggle(layer.name, isOn: Binding(get: {
            model.calendar.settings.connection(source).layerIDs?.contains(layer.id) ?? true
        }, set: { enabled in
            let available = model.calendar.layers(for: source).map(\.id)
            model.calendar.updateSettings { settings in
                var connection = settings.connection(source)
                var ids = Set(connection.layerIDs ?? available)
                if enabled { ids.insert(layer.id) } else { ids.remove(layer.id) }
                connection.layerIDs = ids.sorted()
                settings.setConnection(connection, for: source)
            }
        })).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CalendarSelectionView: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false
    var body: some View {
        LabeledContent("Календари") {
            Button("Выбрать") { expanded.toggle() }.popover(isPresented: $expanded) { CalendarSelectionPopover(model: model) }
        }
    }
}

struct CalendarSelectionPopover: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Календари").font(.headline)
            TextField("Найти календарь", text: $search)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Edition.calendarSources.filter { model.calendar.settings.connection($0).enabled }) { source in
                        Text(source.title).font(.caption).foregroundStyle(.secondary)
                        ForEach(model.calendar.layers(for: source).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { layer in
                            CalendarLayerToggle(model: model, source: source, layer: layer)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 230)
        }.padding(12).frame(width: 360).background(Color(nsColor: .windowBackgroundColor))
    }
}
