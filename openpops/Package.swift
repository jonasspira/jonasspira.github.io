// swift-tools-version:5.9
import PackageDescription

// OpenPopsCore is plain Foundation code (models, storage, layout math) and also
// builds on Linux so its tests can run anywhere. The app target needs AppKit,
// so it is only added when the package is built on macOS.

var targets: [Target] = [
    .target(
        name: "OpenPopsCore",
        path: "Sources/OpenPopsCore"
    ),
    .testTarget(
        name: "OpenPopsCoreTests",
        dependencies: ["OpenPopsCore"],
        path: "Tests/OpenPopsCoreTests"
    ),
]

var products: [Product] = []

#if os(macOS)
targets.append(
    .executableTarget(
        name: "OpenPops",
        dependencies: ["OpenPopsCore"],
        path: "Sources/OpenPops",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("Quartz"),
            .linkedFramework("QuickLookThumbnailing"),
            .linkedFramework("ServiceManagement"),
            .linkedFramework("UniformTypeIdentifiers"),
        ]
    )
)
products.append(.executable(name: "OpenPops", targets: ["OpenPops"]))
#endif

let package = Package(
    name: "OpenPops",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
