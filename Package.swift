// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchAgent",
            path: "Sources/NotchAgent",
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
