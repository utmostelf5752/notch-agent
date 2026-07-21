// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Eave",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Matches the binary framework pinned in Support/fetch-sparkle.sh.
        // Real builds (build.sh, Xcode) link that vendored copy; this
        // dependency exists so SPM-based indexing resolves `import Sparkle`.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Eave",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Eave",
            linkerSettings: [
                // Embed an Info.plist into the bare executable so it has a
                // main bundle identifier even when run outside a .app bundle
                // (swift run, Xcode SPM scheme). Without one, AppIntents/linkd
                // registration and window-tab indexing spam the console.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/EmbeddedInfo.plist",
                ])
            ]
        )
    ]
)
