import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private weak var model: AppModel?
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                let hasWindow = NSApp.windows.contains {
                    ["Bad Meeting", "Настройки Bad Meeting"].contains($0.title) && ($0.isVisible || $0.isMiniaturized)
                }
                if !hasWindow { NSApp.setActivationPolicy(.accessory) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRecording else { return .terminateNow }
        return model.stopRecording() == nil ? .terminateCancel : .terminateNow
    }

    @MainActor func configureStatusItem(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        guard statusItemController == nil else { return }
        statusItemController = StatusItemController(model: model, openWindow: openWindow)
    }
}

@main
struct BadMeetingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Bad Meeting", id: "main") {
            MainView(model: model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    model.showMainWindow = { show("main") }
                    model.showSettingsWindow = { show("settings") }
                    appDelegate.configureStatusItem(model: model) {
                        show("main")
                    }
                }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { show("settings") }.keyboardShortcut(",")
            }
            CommandMenu("Запись") {
                Button("Начать запись") {
                    Task { await model.recordCurrentMeeting() }
                }
                    .keyboardShortcut("r").disabled(!model.canStartRecording)
                Button("Остановить запись") { model.stopRecording() }
                    .keyboardShortcut(".").disabled(!model.isRecording)
                Button("Остановить и расшифровать") { model.stopAndTranscribe() }.disabled(!model.isRecording)
                if model.isJoining { Button("Отменить ожидание приложения") { model.stopRecording() } }
                Divider()
                Toggle("Записывать микрофон", isOn: $model.microphoneEnabled).disabled(model.recordingBusy)
            }
            CommandMenu("Переход") {
                Button("Сегодня") { model.selectDay(Date()); show("main") }.keyboardShortcut("t")
                Button("Предыдущий день со встречами") { model.moveDay(-1); show("main") }
                    .keyboardShortcut("[").disabled(model.calendar.adjacentDay(to: model.selectedDate, direction: -1) == nil)
                Button("Следующий день со встречами") { model.moveDay(1); show("main") }
                    .keyboardShortcut("]").disabled(model.calendar.adjacentDay(to: model.selectedDate, direction: 1) == nil)
                Divider()
                Button("Все записи") { model.showingAllRecordings = true; show("main") }
            }
            CommandGroup(after: .windowArrangement) {
                Button("Открыть Bad Meeting") { show("main") }.keyboardShortcut("0")
            }
        }
        Window("Настройки Bad Meeting", id: "settings") { SettingsView(model: model).onAppear { NSApp.setActivationPolicy(.regular) } }
            .windowResizability(.contentSize)
    }

    private func show(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

}
