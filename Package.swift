// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskCapture",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "DeskCapture", targets: ["DeskCapture"])],
    targets: [
        .executableTarget(name: "DeskCapture", dependencies: ["Sparkle"],
                          resources: [.copy("Resources/WorkflowSample.png"), .process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // Official 2.10.0 SwiftPM artifact and checksum from sparkle-project/Sparkle.
        .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
                      checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .testTarget(name: "DeskCaptureTests", dependencies: ["DeskCapture"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
