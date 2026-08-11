// swift-tools-version: 6.0
import PackageDescription

// The app is split so it can be tested: everything real lives in the DiktaCore
// library, and the Dikta executable is a thin main.swift over it. Test targets
// cannot meaningfully import an executable target, and `@testable import
// DiktaCore` keeps internal access without making the API public.
let package = Package(
    name: "Dikta",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DiktaCore",
            dependencies: ["whisper"],
            path: "Sources/DiktaCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "Dikta",
            dependencies: ["DiktaCore"],
            path: "Sources/Dikta"
        ),
        .executableTarget(
            name: "DiktaTests",
            dependencies: ["DiktaCore"],
            path: "Sources/DiktaTests"
        ),
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
    ]
)
