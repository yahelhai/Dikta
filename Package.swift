// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dikta",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dikta",
            dependencies: ["whisper"],
            path: "Sources/Dikta",
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
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
    ]
)
