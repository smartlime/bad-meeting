import AVFAudio
import AppKit
import CoreAudio
import Foundation

struct ApplicationAudioSource: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let bundleID: String
}

enum ApplicationAudio {
    static func availableSources() -> [ApplicationAudioSource] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let result = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!
            )
        }
        guard result == noErr else { return [] }
        return objectIDs.compactMap { objectID in
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            pidAddress.mSelector = kAudioProcessPropertyBundleID
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout.size(ofValue: bundle))
            let status = AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &bundleSize, &bundle)
            let bundleID = status == noErr ? (bundle?.takeRetainedValue() as String? ?? "") : (app?.bundleIdentifier ?? "")
            guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return nil }
            let name = app?.localizedName ?? bundleID
            return ApplicationAudioSource(id: objectID, name: name, bundleID: captureBundleID(
                bundleID, name: name, executablePath: app?.executableURL?.path ?? ""
            ))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func captureBundleID(_ bundleID: String, name: String, executablePath: String) -> String {
        if bundleID.hasPrefix("com.apple.WebKit."), name.hasPrefix("Safari "),
           executablePath.contains("/StagedFrameworks/Safari/WebKit.framework/") {
            return "com.apple.Safari"
        }
        return bundleID
    }

    static let supportedBundles = [
        "us.zoom.xos", "ru.yandex.desktop.telemost", "ru.yandex.Telemost", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram",
        "com.apple.Safari", "com.google.Chrome", "ru.yandex.desktop.yandex-browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"
    ]

    static func family(_ bundle: String) -> String? {
        if bundle.hasPrefix("us.zoom.") { return "us.zoom.xos" }
        return supportedBundles.first { bundle == $0 || bundle.hasPrefix($0 + ".") }
    }

    static func belongsToApplication(_ bundle: String, target: String) -> Bool {
        if let targetFamily = family(target) { return family(bundle) == targetFamily }
        return bundle == target || bundle.hasPrefix(target + ".")
    }

    static func selectableSources() -> [ApplicationAudioSource] {
        var groups: [String: ApplicationAudioSource] = [:]
        let browser = LSCopyDefaultHandlerForURLScheme("https" as CFString)?.takeRetainedValue() as String?
        for source in availableSources() {
            guard let family = family(source.bundleID) ?? browser.flatMap({
                source.bundleID == $0 || source.bundleID.hasPrefix($0 + ".") ? $0 : nil
            }) else { continue }
            if groups[family] == nil || source.bundleID == family {
                let name = NSRunningApplication.runningApplications(withBundleIdentifier: family).first?.localizedName ?? source.name
                groups[family] = ApplicationAudioSource(id: source.id, name: displayName(bundleID: family, fallback: name), bundleID: family)
            }
        }
        return groups.values.sorted {
            let left = sourcePriority($0.bundleID)
            let right = sourcePriority($1.bundleID)
            return left == right ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : left < right
        }
    }

    static func sourcePriority(_ bundleID: String) -> Int {
        switch bundleID {
        case "us.zoom.xos": return 0
        case "ru.yandex.desktop.telemost", "ru.yandex.Telemost": return 1
        default: return 2
        }
    }

    static func displayName(bundleID: String, fallback: String) -> String {
        switch bundleID {
        case "us.zoom.xos": return "Zoom"
        case "ru.yandex.desktop.telemost", "ru.yandex.Telemost": return "Телемост"
        case "ru.yandex.desktop.yandex-browser": return "Яндекс Браузер"
        default: return fallback
        }
    }

    static func preferredSource(from sources: [ApplicationAudioSource]) -> ApplicationAudioSource? {
        let meetingApps = sources.filter {
            $0.bundleID == "us.zoom.xos" || $0.bundleID == "ru.yandex.desktop.telemost"
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let source = meetingApps.first(where: { $0.bundleID == frontmost }) {
            return source
        }
        return meetingApps.first { $0.bundleID == "us.zoom.xos" } ?? meetingApps.first
    }
}

final class MicrophoneCapture {
    private let engine = AVAudioEngine()

    func start(recorder: SegmentedRecorder) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecordingError.noAudio }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            recorder.append(buffer, source: "microphone", hostTime: time.hostTime)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

enum ApplicationAudioError: LocalizedError {
    case systemCall(String, OSStatus)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case let .systemCall(name, status): "Не удалось захватить звук приложения: \(name), код \(status)."
        case .invalidFormat: "Не удалось определить формат звука приложения."
        }
    }
}

final class ApplicationAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var processListener: AudioObjectPropertyListenerBlock?

    func start(source: ApplicationAudioSource, recorder: SegmentedRecorder) throws {
        let grouped = ApplicationAudio.availableSources().filter {
            ApplicationAudio.belongsToApplication($0.bundleID, target: source.bundleID)
        }.map(\.id)
        let processIDs = grouped.isEmpty ? [source.id] : grouped
        let description = CATapDescription(monoMixdownOfProcesses: processIDs)
        description.name = "BadMeeting \(source.name)"
        description.isPrivate = true
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else { throw ApplicationAudioError.systemCall("AudioHardwareCreateProcessTap", tapStatus) }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) { pointer in
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard uidStatus == noErr else {
            stop()
            throw ApplicationAudioError.systemCall("kAudioTapPropertyUID", uidStatus)
        }

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BadMeeting Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            stop()
            throw ApplicationAudioError.systemCall("AudioHardwareCreateAggregateDevice", aggregateStatus)
        }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var descriptionFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &descriptionFormat)
        guard formatStatus == noErr, let format = AVAudioFormat(streamDescription: &descriptionFormat) else {
            stop()
            throw ApplicationAudioError.invalidFormat
        }

        let queue = DispatchQueue(label: "BadMeeting.audio.tap", qos: .userInitiated)
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            _, inputData, inputTime, _, _ in
            let bufferList = inputData.pointee
            guard bufferList.mNumberBuffers > 0 else { return }
            let bytesPerFrame = Int(descriptionFormat.mBytesPerFrame)
            guard bytesPerFrame > 0 else { return }
            let frames = Int(bufferList.mBuffers.mDataByteSize) / bytesPerFrame
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: UnsafeMutablePointer(mutating: inputData),
                    deallocator: nil
                  )
            else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            recorder.append(buffer, source: "application", hostTime: inputTime.pointee.mHostTime)
        }
        guard procStatus == noErr else {
            stop()
            throw ApplicationAudioError.systemCall("AudioDeviceCreateIOProcIDWithBlock", procStatus)
        }
        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            stop()
            throw ApplicationAudioError.systemCall("AudioDeviceStart", startStatus)
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self, weak recorder] _, _ in
            guard let self, self.tapID != AudioObjectID(kAudioObjectUnknown) else { return }
            let ids = ApplicationAudio.availableSources().filter {
                ApplicationAudio.belongsToApplication($0.bundleID, target: source.bundleID)
            }.map(\.id)
            guard Set(ids) != Set(description.processes) else { return }
            let previous = description.processes
            description.processes = ids
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var updated = Unmanaged.passUnretained(description).toOpaque()
            let status = AudioObjectSetPropertyData(self.tapID, &address, 0, nil,
                                                   UInt32(MemoryLayout.size(ofValue: updated)), &updated)
            if status != noErr {
                description.processes = previous
                recorder?.onFailure?(ApplicationAudioError.systemCall("kAudioTapPropertyDescription", status))
            }
        }
        var processAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listenerStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &processAddress, .main, listener
        )
        guard listenerStatus == noErr else {
            stop()
            throw ApplicationAudioError.systemCall("AudioObjectAddPropertyListenerBlock", listenerStatus)
        }
        processListener = listener
        listener(0, &processAddress)
    }

    func stop() {
        if let processListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, processListener)
            self.processListener = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
