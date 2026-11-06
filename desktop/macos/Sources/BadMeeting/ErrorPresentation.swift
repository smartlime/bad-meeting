import AppKit
import Foundation

protocol ErrorDiagnosticsProviding {
    var diagnosticDetails: String { get }
}

@MainActor
final class ErrorPresenter {
    private struct Issue {
        let message: String
        let details: String
        let showDetails: Bool
        let retry: (() -> Void)?
    }

    private var pending: [Issue] = []
    private var isShowing = false
    private var activeAlert: NSAlert?

    func present(_ error: Error, context: String? = nil, debugMode: Bool, retry: (() -> Void)? = nil) {
        let message = [context, error.localizedDescription].compactMap { $0 }.joined(separator: ": ")
        let details: String
        if let diagnosed = error as? ErrorDiagnosticsProviding {
            details = diagnosed.diagnosticDetails
        } else {
            let nsError = error as NSError
            details = """
            Операция: \(context ?? "Не указана")
            Тип ошибки: \(String(reflecting: type(of: error)))
            Домен: \(nsError.domain)
            Код: \(nsError.code)
            Описание: \(error.localizedDescription)
            """
        }
        pending.append(Issue(message: message, details: details, showDetails: debugMode, retry: retry))
        showNext()
    }

    private func showNext() {
        guard !isShowing, !pending.isEmpty else { return }
        isShowing = true
        let issue = pending.removeFirst()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Bad Meeting"
        alert.informativeText = issue.message
        if issue.retry != nil { alert.addButton(withTitle: "Повторить") }
        alert.addButton(withTitle: "Закрыть")
        activeAlert = alert
        if issue.showDetails {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
            scroll.borderType = .bezelBorder
            if let field = scroll.documentView as? NSTextView {
                field.string = issue.details
                field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                field.isEditable = false
                field.isSelectable = true
                field.isRichText = false
                field.textContainerInset = NSSize(width: 8, height: 8)
            }
            alert.accessoryView = scroll
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { [weak self] response in
                    Task { @MainActor in self?.didDismiss(retry: response == .alertFirstButtonReturn ? issue.retry : nil) }
                }
            } else {
                let response = alert.runModal()
                self.didDismiss(retry: response == .alertFirstButtonReturn ? issue.retry : nil)
            }
        }
    }

    private func didDismiss(retry: (() -> Void)? = nil) {
        activeAlert = nil
        isShowing = false
        retry?()
        showNext()
    }
}
