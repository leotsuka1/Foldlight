// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Foldlight",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Foldlight", targets: ["Foldlight"])],
    targets: [
        .executableTarget(name: "Foldlight", linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("MetalKit"), .linkedFramework("MetalPerformanceShaders"), .linkedFramework("IOKit")
        ])
    ]
)
