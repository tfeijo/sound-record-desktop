// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MeetNotesApp",
    platforms: [
        .macOS(.v14)
    ],
    // TODO: US-016 — Add whisper.cpp as SPM dependency when migrating to Xcode project.
    // The whisper.cpp repo (https://github.com/ggerganov/whisper.cpp) does not expose a
    // stable Package.swift for the versions we need. With an Xcode project we can vendor
    // the C sources directly or use a local package reference.
    //
    // dependencies: [
    //     .package(url: "https://github.com/ggerganov/whisper.cpp.git", branch: "master"),
    // ],
    targets: [
        .executableTarget(
            name: "MeetNotesApp",
            path: ".",
            exclude: [
                "Package.swift",
                "Info.plist",
                "MeetNotes.entitlements",
                // C bridge files excluded until whisper.cpp is vendored via Xcode project.
                // They are kept in the repo as architectural reference.
                "Bridge/whisper-bridge.h",
                "Bridge/whisper-bridge.c",
            ]
        )
    ]
)
