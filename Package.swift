// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LectureNotes",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LectureNotes",
            path: "Sources/LectureNotes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
