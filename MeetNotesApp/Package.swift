// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MeetNotesApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MeetNotesApp",
            path: ".",
            exclude: ["Package.swift", "Info.plist", "MeetNotes.entitlements"]
        )
    ]
)
