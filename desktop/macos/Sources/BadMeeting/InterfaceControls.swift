import AppKit
import SwiftUI

struct ExpansionControl: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: expanded ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct NumericSettingField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var draft = ""

    private var text: Binding<String> {
        Binding(get: { draft }, set: { candidate in
            guard candidate.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
            draft = candidate
            if let number = Int(candidate), range.contains(number) { value = number }
        })
    }

    var body: some View {
        HStack(spacing: 4) {
            DigitsTextField(title: title, text: text, commit: commit)
                .frame(width: 48, height: 22)
            Stepper(title, value: Binding(get: { value }, set: {
                value = $0
                draft = String($0)
            }), in: range).labelsHidden().fixedSize()
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, newValue in
            if Int(draft) != newValue { draft = String(newValue) }
        }
    }

    private func commit() {
        let number = Int(draft) ?? (draft.isEmpty ? value : range.upperBound)
        value = min(range.upperBound, max(range.lowerBound, number))
        draft = String(value)
    }
}

private final class DigitsFormatter: Formatter {
    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard string.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String,
                                       newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partialString.utf8.allSatisfy { (48...57).contains($0) }
    }
}

private struct DigitsTextField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    let commit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        field.font = .systemFont(ofSize: 12)
        field.formatter = DigitsFormatter()
        field.delegate = context.coordinator
        field.setAccessibilityLabel(title)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.commit = commit
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>?
        var commit: (() -> Void)?
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text?.wrappedValue = field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) { commit?() }
    }
}

struct LinkedText: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = NSFont.systemFontSize
    var lineSpacing: CGFloat = 0
    var lineLimit: Int? = nil
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openURL = openURL
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        for match in CalendarParser.links(text) {
            if let url = match.url { attributed.addAttribute(.link, value: url, range: match.range) }
        }
        if view.textStorage != attributed { view.textStorage?.setAttributedString(attributed) }
        view.textContainer?.maximumNumberOfLines = lineLimit ?? 0
        view.textContainer?.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = max(1, proposal.width ?? 300)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            openURL?(url)
            return true
        }
    }
}

private struct LinkCursor: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }.onDisappear {
            if hovering { NSCursor.pop(); hovering = false }
        }
    }
}

extension View {
    func linkCursor() -> some View { modifier(LinkCursor()) }
}

struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
