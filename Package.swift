// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "HaishinKit",
    platforms: [
        .iOS(.v9),
        .tvOS(.v10),
        .macOS(.v10_11)
    ],
    products: [
        .library(name: "HaishinKit", type: .dynamic, targets: ["HaishinKit"])
    ],
    dependencies: [
		.package(url: "https://github.com/shogo4405/Logboard.git", "2.4.1"..."2.4.1"),
		.package(url: "https://github.com/Kitura/BlueSocket.git", from: "1.0.200"),
    ],
    targets: [
        .target(name: "SwiftPMSupport"),
        .target(name: "HaishinKit", dependencies: ["Logboard", "SwiftPMSupport", "Socket"],
                path: "Sources",
                sources: [
                    "Codec",
                    "Extension",
                    "FLV",
                    "HTTP",
                    "ISO",
                    "Media",
                    "Net",
                    "PiP",
					"RTMP",
                    "Util",
                    "Platforms"
                ])
    ]
)
