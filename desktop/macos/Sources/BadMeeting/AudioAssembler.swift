import AVFAudio
import Foundation

enum AudioAssembler {
    static func makeUploadFile(for meeting: Meeting, in directory: URL) throws -> URL {
        guard !meeting.segments.isEmpty else { throw RecordingError.noAudio }
        let token = UUID().uuidString
        let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-\(token).raw")
        let waveURL = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-\(token).wav")
        var completed = false
        defer {
            try? FileManager.default.removeItem(at: rawURL)
            if !completed { try? FileManager.default.removeItem(at: waveURL) }
        }
        _ = FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        let raw = try FileHandle(forUpdating: rawURL)
        defer { try? raw.close() }

        var totalFrames: UInt64 = 0
        for segment in meeting.segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(segment.fileName))
            let position = UInt64(max(0, (segment.startSeconds * 16_000).rounded()))
            var current = position
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                throw RecordingError.conversionFailed
            }
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition))
                try file.read(into: buffer, frameCount: remaining)
                if buffer.frameLength == 0 { break }
                guard let channel = buffer.floatChannelData?[0] else { throw RecordingError.conversionFailed }
                let count = Int(buffer.frameLength)
                let offset = current * 2
                try raw.seek(toOffset: offset)
                let existing = try raw.read(upToCount: count * 2) ?? Data()
                var mixed = Data(count: count * 2)
                mixed.withUnsafeMutableBytes { output in
                    let samples = output.bindMemory(to: Int16.self)
                    for index in 0..<count {
                        let old: Int16 = existing.count >= (index + 1) * 2
                            ? existing.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 2, as: Int16.self) }
                            : 0
                        let added = Int32((max(-1, min(1, channel[index])) * 16_000).rounded())
                        samples[index] = Int16(clamping: Int32(old) + added)
                    }
                }
                try raw.seek(toOffset: offset)
                try raw.write(contentsOf: mixed)
                current += UInt64(count)
            }
            totalFrames = max(totalFrames, current)
        }

        _ = FileManager.default.createFile(atPath: waveURL.path, contents: nil)
        let wave = try FileHandle(forWritingTo: waveURL)
        defer { try? wave.close() }
        try wave.write(contentsOf: waveHeader(frameCount: totalFrames))
        try raw.seek(toOffset: 0)
        while let chunk = try raw.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try wave.write(contentsOf: chunk)
        }
        completed = true
        return waveURL
    }

    private static func waveHeader(frameCount: UInt64) -> Data {
        let dataSize = UInt32(clamping: frameCount * 2)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(16_000))
        data.appendLE(UInt32(32_000))
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
