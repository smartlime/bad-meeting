import AppKit

struct MeetingApplication: Equatable {
    let bundleID: String
    let name: String
    let applicationURL: URL

    func source(in sources: [ApplicationAudioSource]) -> ApplicationAudioSource? {
        sources.first { ApplicationAudio.belongsToApplication($0.bundleID, target: bundleID) }
    }
}

@MainActor
struct MeetingApplicationLauncher {
    var resolve: (URL) -> MeetingApplication?
    var launch: (MeetingApplication, URL?) async -> Bool
    var pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    var attempts = 20

    static func nativeBundles(for url: URL) -> [String] {
        switch CalendarEvent.videoProvider(url) {
        case "Zoom": return ["us.zoom.xos"]
        case "Телемост": return ["ru.yandex.desktop.telemost", "ru.yandex.Telemost"]
        case "Telegram": return ["ru.keepcoder.Telegram", "com.tdesktop.Telegram", "org.telegram.desktop"]
        default: return []
        }
    }

    static var live: Self {
        Self(resolve: { url in
            let workspace = NSWorkspace.shared
            var bundles = nativeBundles(for: url)
            if CalendarEvent.videoProvider(url) == "Telegram",
               let preferred = LSCopyDefaultHandlerForURLScheme("tg" as CFString)?.takeRetainedValue() as String?, bundles.contains(preferred) {
                bundles = [preferred] + bundles.filter { $0 != preferred }
            }
            let native = bundles.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
            guard let applicationURL = native ?? workspace.urlForApplication(toOpen: url),
                  let bundle = Bundle(url: applicationURL), let bundleID = bundle.bundleIdentifier else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundleID
            return MeetingApplication(bundleID: bundleID, name: ApplicationAudio.displayName(bundleID: bundleID, fallback: name), applicationURL: applicationURL)
        }, launch: { application, url in
            let nativeLink = url.map { nativeBundles(for: $0).contains(application.bundleID) } ?? false
            let opened: Bool = await withCheckedContinuation { continuation in
                let configuration = NSWorkspace.OpenConfiguration()
                let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
                    continuation.resume(returning: app != nil && error == nil)
                }
                if let url, !nativeLink {
                    NSWorkspace.shared.open([url], withApplicationAt: application.applicationURL, configuration: configuration, completionHandler: completion)
                } else {
                    NSWorkspace.shared.openApplication(at: application.applicationURL, configuration: configuration, completionHandler: completion)
                }
            }
            guard opened, nativeLink, let url else { return opened }
            return NSWorkspace.shared.open(url)
        })
    }
}
