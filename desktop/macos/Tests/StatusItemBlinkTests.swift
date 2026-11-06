@testable import BadMeetingKit
import AppKit
import QuartzCore

@main
struct StatusItemBlinkTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = item.button!
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let cassette = NSImage(contentsOf: resources.appendingPathComponent("Cassette.png"))!
        cassette.size = NSSize(width: 18, height: 18)
        cassette.isTemplate = true
        button.image = cassette
        let badge = MenuRecordingBadge()
        badge.image = NSImage(contentsOf: resources.appendingPathComponent("RecordingBadge.png"))!
        badge.image?.size = NSSize(width: 18, height: 18)
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18)
        ])
        badge.setRecording(false)
        try await Task.sleep(for: .milliseconds(200))
        precondition(badge.isHidden)
        badge.setRecording(true)
        let animation = badge.layer?.animation(forKey: "recordingBlink") as! CAKeyframeAnimation
        precondition(abs(animation.duration - 1.0 / 1.95) < 0.000001)
        var samples: [Bool] = []
        for index in 0..<60 {
            try await Task.sleep(for: .milliseconds(30))
            if index % 10 == 0 { badge.setRecording(true) }
            let visible = !badge.isHidden && (badge.layer?.presentation()?.opacity ?? 1) > 0.5
            samples.append(visible)
        }
        let transitions = zip(samples, samples.dropFirst()).filter { $0 != $1 }.count
        print("Visible samples: " + samples.map { $0 ? "1" : "0" }.joined())
        guard transitions >= 5 && transitions <= 9 else {
            fputs("FAIL: expected 1.95 Hz blinking; transitions=\(transitions)\n", stderr)
            exit(1)
        }
        badge.setRecording(false)
        try await Task.sleep(for: .milliseconds(600))
        precondition(badge.isHidden && badge.layer?.animation(forKey: "recordingBlink") == nil)
        badge.setRecording(true)
        try await Task.sleep(for: .milliseconds(350))
        precondition(!badge.isHidden && (badge.layer?.presentation()?.opacity ?? 1) < 0.5)
        badge.setRecording(false)
        precondition(badge.hitTest(NSPoint(x: 15, y: 2)) == nil)
        print("PASS: \(transitions) transitions; repeated updates, stop, restart, and click passthrough verified")
    }
}
