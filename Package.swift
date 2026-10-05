// swift-tools-version: 5.9
import PackageDescription

// The Espobase client for Swift (iOS, macOS, tvOS, watchOS and server-side Swift). No dependencies: HTTP is
// URLSession, hashing is plain Swift. See README.md.
let package = Package(
    name: "Espobase",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [
        .library(name: "Espobase", targets: ["Espobase"]),
    ],
    targets: [
        .target(name: "Espobase"),
        .testTarget(name: "EspobaseTests", dependencies: ["Espobase"]),
    ]
)
