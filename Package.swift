// swift-tools-version:6.0
import PackageDescription

// Swift-only Raptor: the Go backend ported package-for-package, same CLI
// surface and NDJSON api protocol so the native app needs no changes.
let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let packages: [(name: String, deps: [String])] = [
    ("RaptorPaths", []),
    ("RaptorExecx", ["RaptorPaths"]),
    ("RaptorConfig", ["RaptorPaths"]),
    ("RaptorRexconfig", ["RaptorPaths"]),
    ("RaptorLauncherupdate", ["RaptorPaths"]),
    ("RaptorTheme", ["RaptorPaths"]),
    ("RaptorPanel", ["RaptorPaths"]),
    ("RaptorRex", ["RaptorExecx", "RaptorPaths", "RaptorLauncherupdate"]),
    ("RaptorWorktree", ["RaptorConfig", "RaptorExecx", "RaptorPaths"]),
    ("RaptorCatalog", ["RaptorConfig", "RaptorPaths", "RaptorRex", "RaptorWorktree"]),
    ("RaptorPullrequest", ["RaptorPaths", "RaptorRex", "RaptorWorktree"]),
    ("RaptorDispatch", ["RaptorConfig", "RaptorPaths", "RaptorPullrequest", "RaptorRex"]),
    ("RaptorTask", ["RaptorCatalog", "RaptorConfig", "RaptorPaths", "RaptorPullrequest", "RaptorRex", "RaptorWorktree"]),
    ("RaptorAPI", ["RaptorCatalog", "RaptorConfig", "RaptorDispatch", "RaptorLauncherupdate", "RaptorPaths", "RaptorPullrequest", "RaptorRex", "RaptorTheme", "RaptorWorktree"]),
]

let targets = packages.map { pkg in
    Target.target(
        name: pkg.name,
        dependencies: pkg.deps.map { Target.Dependency(stringLiteral: $0) },
        swiftSettings: settings
    )
}

let testTargets = packages.map { pkg in
    Target.testTarget(
        name: "\(pkg.name)Tests",
        dependencies: [Target.Dependency(stringLiteral: pkg.name)],
        swiftSettings: settings
    )
}

let cli = Target.executableTarget(
    name: "raptor",
    dependencies: packages.map { Target.Dependency(stringLiteral: $0.name) },
    swiftSettings: settings
)

let package = Package(
    name: "raptor",
    platforms: [.macOS(.v14)],
    targets: targets + testTargets + [cli]
)
