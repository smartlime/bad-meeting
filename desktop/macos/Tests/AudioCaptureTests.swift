@testable import BadMeetingKit
import AppKit
import AVFAudio
import CoreAudio

@main
struct AudioCaptureTests {
    static func main() throws {
        let safariPath = "/System/Library/StagedFrameworks/Safari/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        precondition(ApplicationAudio.captureBundleID("com.apple.WebKit.GPU", name: "Safari Graphics and Media", executablePath: safariPath) == "com.apple.Safari")
        precondition(ApplicationAudio.captureBundleID("com.apple.WebKit.GPU", name: "Other Graphics and Media", executablePath: safariPath) == "com.apple.WebKit.GPU")
        precondition(ApplicationAudio.captureBundleID("com.apple.WebKit.GPU", name: "Safari Graphics and Media", executablePath: "/Other/WebKit.framework/GPU") == "com.apple.WebKit.GPU")
        if CommandLine.arguments.contains("--live-inventory") {
            let sources = ApplicationAudio.availableSources()
            let helper = sources.first { $0.name == "Safari Graphics and Media" }!
            precondition(ApplicationAudio.family(helper.bundleID) == "com.apple.Safari",
                         "Safari's audio helper is excluded from the capture group")
            print("Safari media process is included in the capture group")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(id: UUID(), createdAt: Date(), title: "Silence", status: .recording,
                              sourceName: "Safari", segments: [], transcript: nil, transcriptionError: nil)
        try store.save(meeting)
        let recorder = SegmentedRecorder(meeting: meeting, store: store, format: .pcm16)
        var errors = 0
        recorder.onFailure = { _ in errors += 1 }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0 }
        for _ in 0..<35 { recorder.append(buffer, source: "application", hostTime: mach_absolute_time()) }
        _ = recorder.snapshot()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(errors == 1, "A source producing only zeros must report an error during recording, once")
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0.001 }
        for _ in 0..<35 { recorder.append(buffer, source: "microphone", hostTime: mach_absolute_time()) }
        _ = recorder.snapshot()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(errors == 1, "Quiet nonzero microphone input must not be reported as digital silence")
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0 }
        for _ in 0..<35 { recorder.append(buffer, source: "microphone", hostTime: mach_absolute_time()) }
        _ = recorder.snapshot()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(errors == 2, "Each source must detect digital silence independently")
        let finished = recorder.finish(interrupted: false)
        precondition(!finished.segments.isEmpty, "Silence detection must preserve the original files")
        print("Silent capture reports an error without discarding audio")
    }
}
