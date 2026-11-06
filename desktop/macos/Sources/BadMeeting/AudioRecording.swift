import AVFAudio
import CoreAudio
import Foundation

enum RecordingError: LocalizedError {
    case microphoneDenied
    case noAudio
    case conversionFailed
    case silentSource(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Доступ к микрофону не предоставлен."
        case .noAudio: "Запись не содержит сохранённых аудиосегментов."
        case .conversionFailed: "Не удалось преобразовать аудиобуфер в формат записи."
        case .silentSource(let source): "Источник «\(source)» 30 секунд передаёт только нулевые аудиоотсчёты. Звук из этого источника не записывается."
        }
    }
}

enum AudioStorageFormat: String, CaseIterable, Identifiable {
    case pcm16
    case aac32
    case aac16

    var id: String { rawValue }
    static let defaultsKey = "BadMeeting.audioStorageFormat"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let format = defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .aac32
        defaults.set(format.rawValue, forKey: defaultsKey)
        return format
    }

    var title: String {
        switch self {
        case .pcm16: "Без сжатия (PCM, 16 бит)"
        case .aac32: "AAC, 32 кбит/с"
        case .aac16: "AAC, 16 кбит/с"
        }
    }

    var fileExtension: String { self == .pcm16 ? "caf" : "m4a" }

    var settings: [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]
        if self == .pcm16 {
            settings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        } else {
            settings[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC)
            settings[AVEncoderBitRateKey] = self == .aac32 ? 32_000 : 16_000
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_LongTermAverage
        }
        return settings
    }
}

final class SegmentedRecorder {
    private struct OpenSegment {
        let source: String
        let fileName: String
        let startSeconds: Double
        var file: AVAudioFile?
        var frames: Int64 = 0
    }

    private let format: AudioStorageFormat
    private let store: MeetingStore
    private let directory: URL
    private let queue = DispatchQueue(label: "BadMeeting.audio.writer", qos: .userInitiated)
    private let startedHostTime = mach_absolute_time()
    private var openSegments: [String: OpenSegment] = [:]
    private var sequence: [String: Int] = [:]
    private var converters: [String: AVAudioConverter] = [:]
    private var stopped = false
    private var silentFrames: [String: Int64] = [:]
    private var warnedSilentSources: Set<String> = []
    private var lastLevelUpdate = 0.0
    private(set) var meeting: Meeting
    var onUpdate: ((Meeting) -> Void)?
    var onLevel: ((Float) -> Void)?

    init(meeting: Meeting, store: MeetingStore, format: AudioStorageFormat = .aac32) {
        self.format = format
        self.meeting = meeting
        self.store = store
        self.directory = store.directory(for: meeting.id)
    }

    func append(_ buffer: AVAudioPCMBuffer, source: String, hostTime: UInt64) {
        guard let copied = buffer.copied() else { return }
        queue.async { [self] in
            guard !stopped else { return }
            do {
                guard let target = try convertToRecordingFormat(copied, source: source) else { return }
                checkSignal(target, source: source)
                let origin = AudioConvertHostTimeToNanos(startedHostTime)
                let current = AudioConvertHostTimeToNanos(hostTime)
                let elapsed = Double(current >= origin ? current - origin : 0) / 1_000_000_000
                publishLevel(from: target)
                try write(target, source: source, startSeconds: max(0, elapsed))
            } catch {
                DispatchQueue.main.async { [self] in onFailure?(error) }
            }
        }
    }

    var onFailure: ((Error) -> Void)?

    func snapshot() -> Meeting { queue.sync { meeting } }

    func setSourceName(_ name: String) {
        queue.sync {
            meeting.sourceName = name
            if meeting.sourceChanges == nil { meeting.sourceChanges = [] }
            meeting.sourceChanges?.append(SourceChange(at: Date(), name: name))
            do {
                try store.save(meeting)
            } catch {
                DispatchQueue.main.async { [self] in onFailure?(error) }
            }
        }
    }

    func updateMetadata(title: String, event: CalendarEvent?) throws -> Meeting {
        try queue.sync {
            meeting.title = title
            meeting.calendarEvent = event
            try store.save(meeting)
            return meeting
        }
    }

    func finish(interrupted: Bool) -> Meeting {
        onUpdate = nil
        onLevel = nil
        return queue.sync {
            stopped = true
            for source in Array(openSegments.keys) { close(source: source) }
            meeting.status = interrupted || meeting.segments.isEmpty ? .interrupted : .ready
            meeting.endedAt = Date()
            do {
                try store.save(meeting)
            } catch {
                DispatchQueue.main.async { [self] in onFailure?(error) }
            }
            if meeting.segments.isEmpty {
                DispatchQueue.main.async { [self] in onFailure?(RecordingError.noAudio) }
            }
            return meeting
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, source: String, startSeconds: Double) throws {
        if let current = openSegments[source], current.frames >= 30 * 16_000 {
            close(source: source)
        }
        if openSegments[source] == nil {
            let number = (sequence[source] ?? 0) + 1
            sequence[source] = number
            let fileName = String(format: "%@-%05d.%@", source, number, format.fileExtension)
            let file = try AVAudioFile(
                forWriting: directory.appendingPathComponent(fileName),
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            openSegments[source] = OpenSegment(source: source, fileName: fileName, startSeconds: startSeconds, file: file)
        }
        try openSegments[source]?.file?.write(from: buffer)
        openSegments[source]?.frames += Int64(buffer.frameLength)
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastLevelUpdate >= 0.1, let samples = buffer.floatChannelData?[0] else { return }
        lastLevelUpdate = now
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var power: Float = 0
        for index in 0..<count { power += samples[index] * samples[index] }
        let level = min(1, sqrt(power / Float(count)) * 4)
        DispatchQueue.main.async { [self] in onLevel?(level) }
    }

    private func checkSignal(_ buffer: AVAudioPCMBuffer, source: String) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let hasSignal = (0..<Int(buffer.frameLength)).contains { samples[$0] != 0 }
        silentFrames[source] = hasSignal ? 0 : (silentFrames[source] ?? 0) + Int64(buffer.frameLength)
        guard silentFrames[source, default: 0] >= 30 * 16_000,
              warnedSilentSources.insert(source).inserted else { return }
        let name = source == "microphone" ? "Микрофон" : "Звук приложения"
        DispatchQueue.main.async { [self] in onFailure?(RecordingError.silentSource(name)) }
    }

    private func close(source: String) {
        guard var segment = openSegments.removeValue(forKey: source) else { return }
        let duration = Double(segment.frames) / 16_000
        if #available(macOS 15.0, *) { segment.file?.close() }
        segment.file = nil
        guard duration > 0 else { return }
        meeting.segments.append(AudioSegment(
            id: UUID(), source: source, fileName: segment.fileName,
            startSeconds: segment.startSeconds, durationSeconds: duration
        ))
        do {
            try store.save(meeting)
            let snapshot = meeting
            DispatchQueue.main.async { [self] in onUpdate?(snapshot) }
        } catch {
            DispatchQueue.main.async { [self] in onFailure?(error) }
        }
    }

    private func convertToRecordingFormat(_ input: AVAudioPCMBuffer, source: String) throws -> AVAudioPCMBuffer? {
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        if input.format.isEqual(outputFormat) { return input }
        if converters[source]?.inputFormat.isEqual(input.format) != true {
            converters[source] = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter = converters[source], let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate + 256)
              )
        else { throw RecordingError.conversionFailed }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            throw conversionError ?? RecordingError.conversionFailed
        }
        return output.frameLength > 0 ? output : nil
    }
}

private extension AVAudioPCMBuffer {
    func copied() -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        result.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return result
    }
}
