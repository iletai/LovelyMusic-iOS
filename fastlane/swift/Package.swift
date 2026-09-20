// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "fastlaneRunner",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fastlaneRunner", targets: ["fastlaneRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/fastlane/fastlane", from: "2.225.0")
    ],
    targets: [
        .executableTarget(
            name: "fastlaneRunner",
            dependencies: [
                .product(name: "Fastlane", package: "fastlane")
            ],
            path: "."
        )
    ]
)
