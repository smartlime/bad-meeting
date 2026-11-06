import AppKit
import QuartzCore

final class MenuRecordingBadge: NSImageView {
    func setRecording(_ isRecording: Bool) {
        wantsLayer = true
        isHidden = !isRecording
        if isRecording {
            guard layer?.animation(forKey: "recordingBlink") == nil else { return }
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1.0, 0.0, 0.0]
            blink.keyTimes = [0.0, 0.5, 1.0]
            blink.calculationMode = .discrete
            blink.duration = 1.0 / 1.95
            blink.repeatCount = .infinity
            layer?.add(blink, forKey: "recordingBlink")
        } else {
            layer?.removeAnimation(forKey: "recordingBlink")
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
