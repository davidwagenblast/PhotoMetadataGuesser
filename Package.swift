// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhotoMetadataGuesser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoMetadataGuesser", targets: ["PhotoMetadataGuesser"]),
        .library(name: "DateGuessCore", targets: ["DateGuessCore"]),
    ],
    targets: [
        // Pure-Foundation logic: clue parsing, evidence fusion, Claude request/response handling.
        .target(name: "DateGuessCore"),
        // The macOS app (SwiftUI + PhotoKit + Vision).
        .executableTarget(
            name: "PhotoMetadataGuesser",
            dependencies: ["DateGuessCore"]
        ),
        .testTarget(name: "DateGuessCoreTests", dependencies: ["DateGuessCore"]),
        // Layout checks for the app's SwiftUI screens.
        .testTarget(name: "PhotoMetadataGuesserTests", dependencies: ["PhotoMetadataGuesser", "DateGuessCore"]),
    ]
)
