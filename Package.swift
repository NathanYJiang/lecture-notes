// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LectureNotes",
    platforms: [.macOS(.v26)],
    targets: [
        // whisper.cpp, used for the high-accuracy transcript made after a recording stops.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .executableTarget(
            name: "LectureNotes",
            dependencies: ["whisper"],
            path: "Sources/LectureNotes",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            ])]
        )
    ]
)
