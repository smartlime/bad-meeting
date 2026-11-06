import AVFoundation

@MainActor
struct RecordingInputs {
    var microphonePermission: () async -> Bool
    var startMicrophone: (SegmentedRecorder) throws -> (() -> Void)
    var startApplication: (ApplicationAudioSource, SegmentedRecorder) throws -> (() -> Void)

    static var live: RecordingInputs {
        RecordingInputs(
            microphonePermission: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return true
                case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
                default: return false
                }
            },
            startMicrophone: { recorder in
                let capture = MicrophoneCapture()
                try capture.start(recorder: recorder)
                return { capture.stop() }
            },
            startApplication: { source, recorder in
                let capture = ApplicationAudioCapture()
                try capture.start(source: source, recorder: recorder)
                return { capture.stop() }
            }
        )
    }
}
