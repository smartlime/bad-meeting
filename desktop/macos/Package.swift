// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BadMeeting",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "BadMeeting", targets: ["BadMeeting"])],
    targets: [.executableTarget(name: "BadMeeting", resources: [.copy("MenuBar"), .copy("GitHubMark.svg")])],
    swiftLanguageModes: [.v5]
)
