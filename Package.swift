// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Deck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.19.0" ..< "1.20.0"),
    ],
    targets: [
        .executableTarget(name: "Deck", dependencies: ["SwiftTerm"], path: "Sources/Deck"),
        .testTarget(
            name: "DeckTests",
            dependencies: ["Deck"],
            path: "Tests/DeckTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
