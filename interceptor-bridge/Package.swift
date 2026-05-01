// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "interceptor-bridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "interceptor-bridge",
            path: "Sources",
            // helper subprocess lives in Sources/InterceptorVDHelper —
            // exclude from the main bridge target since it has its own
            // entry point and a separate clean-process design (Lumen pattern).
            // No SwiftPM resource bundling — see scripts/build-bridge.sh, which
            // copies model resources directly into the .app's Contents/Resources/.
            // SwiftPM-generated resource bundles (TargetName_TargetName.bundle)
            // lack an Info.plist and codesign rejects them as nested bundles
            // when the outer .app is signed.
            exclude: ["InterceptorVDHelper", "Resources"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("SoundAnalysis"),
                .linkedFramework("Vision"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("SensitiveContentAnalysis"),
                .linkedFramework("HealthKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                // HTML overlays (OverlayDomain WKWebView mode)
                .linkedFramework("WebKit"),
                // SpriteKit overlays (Titans + scene-script)
                .linkedFramework("SpriteKit"),
                // Apple Events / TCC consent (AEDeterminePermissionToAutomateTarget)
                .linkedFramework("Carbon"),
            ]
        ),
        // tiny clean-process helper that creates a CGVirtualDisplay
        // and holds it alive until SIGTERM. Lives in its own process so
        // that AppKit/SCK/etc framework state doesn't poison the
        // CGVirtualDisplay → WindowServer registration.
        .executableTarget(
            name: "interceptor-vd-helper",
            path: "Sources/InterceptorVDHelper",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "InterceptorBridgeTests",
            dependencies: ["interceptor-bridge"],
            path: "Tests/InterceptorBridgeTests"
        )
    ]
)
