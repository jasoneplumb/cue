// swift-tools-version: 6.0
// Intent: RFC 0003 D3 — wrap kernel/cue_policy.c/.h as a Swift Package C
//         target so the iOS app calls cue_policy_step through C interop.
//         Packaging only: no kernel source changes, no copies, no Swift
//         mirror. The same files keep compiling standalone for MCU targets
//         (NFR-004) via `make -C kernel test`.
// Context: The manifest lives at the repo root because SPM requires target
//          sources under the package root, and kernel/ must stay where the
//          MCU toolchain and replay harness build it — one source of truth
//          by construction (divergence between live and replay is a bug).
// Pattern: CCuePolicy is the raw C module; CueKernel is the thin Swift
//          facade the app imports. Platform floors follow RFC 0003 D8
//          (operator devices, latest stable at implementation time);
//          macOS is listed so `swift test` runs on the development Mac.
import PackageDescription

let package = Package(
    name: "CueKernel",
    platforms: [
        .iOS("26.0"),
        .watchOS("26.0"),
        // macOS is only for running `swift test` — floor stays low so CI's
        // macos-latest runner works regardless of its OS image version.
        .macOS("15.0"),
    ],
    products: [
        .library(name: "CueKernel", targets: ["CueKernel"]),
        .library(name: "CueMapImport", targets: ["CueMapImport"]),
        .library(name: "CueRideEngine", targets: ["CueRideEngine"]),
        .library(name: "CueWatchLink", targets: ["CueWatchLink"]),
        .library(name: "CuePicoLink", targets: ["CuePicoLink"]),
    ],
    targets: [
        .target(
            name: "CCuePolicy",
            path: "kernel",
            sources: ["cue_policy.c"],
            publicHeadersPath: "."
        ),
        .target(
            name: "CueKernel",
            dependencies: ["CCuePolicy"],
            path: "ios/CueKernel/Sources/CueKernel"
        ),
        .testTarget(
            name: "CueKernelTests",
            dependencies: ["CueKernel"],
            path: "ios/CueKernel/Tests/CueKernelTests"
        ),
        // RFC 0003 D1a+D1b: OSM extract -> segments with stable ids ->
        // scored squeeze zones + cache. Depends on the kernel C target
        // ONLY for the spec §7 reason-bit constants (one source of truth,
        // no Swift mirror — D3); the Swift facade stays out of this layer.
        .target(
            name: "CueMapImport",
            dependencies: ["CCuePolicy"],
            path: "ios/CueMapImport/Sources/CueMapImport"
        ),
        .testTarget(
            name: "CueMapImportTests",
            dependencies: ["CueMapImport"],
            path: "ios/CueMapImport/Tests/CueMapImportTests"
        ),
        // RFC 0003 follow-up 5: the ride engine — 1 Hz sample loop feeding
        // the kernel through the D3 facade, zone→RouteEvent conversion over
        // the D2 matcher's graph, and schema-v1 trace export. The one layer
        // allowed to import both the kernel facade and the map layer.
        .target(
            name: "CueRideEngine",
            // CCuePolicy directly for the event-family constant — one
            // source of truth, no redeclared literals (D3).
            dependencies: ["CueKernel", "CueMapImport", "CCuePolicy"],
            path: "ios/CueRideEngine/Sources/CueRideEngine"
        ),
        .testTarget(
            name: "CueRideEngineTests",
            dependencies: ["CueRideEngine", "CCuePolicy"],
            path: "ios/CueRideEngine/Tests/CueRideEngineTests"
        ),
        // RFC 0003 follow-up 6 (D4): the phone→watch cue path's LOGIC —
        // payload, expiry, dispatch policy, latency log — kept platform-
        // neutral so `swift test` covers it on macOS; the WCSession glue
        // lives in the app targets and compiles only under xcodebuild.
        .target(
            name: "CueWatchLink",
            dependencies: ["CueKernel"],
            path: "ios/CueWatchLink/Sources/CueWatchLink"
        ),
        .testTarget(
            name: "CueWatchLinkTests",
            dependencies: ["CueWatchLink"],
            path: "ios/CueWatchLink/Tests/CueWatchLinkTests"
        ),
        // RFC 0006 Phase B2: the phone→Pico link's LOGIC — wire codec,
        // step streamer, shadow-divergence comparator — kept platform-
        // neutral so `swift test` covers it on macOS; the CoreBluetooth
        // glue lives in the app target and compiles only under xcodebuild
        // (same split as CueWatchLink's WCSession glue).
        .target(
            name: "CuePicoLink",
            dependencies: ["CueKernel"],
            path: "ios/CuePicoLink/Sources/CuePicoLink"
        ),
        .testTarget(
            name: "CuePicoLinkTests",
            // CueRideEngine + CueMapImport for the simulated-ride test:
            // driving a real GPX approach is the only way to exercise the
            // cue path end to end without riding past a squeeze zone.
            dependencies: ["CuePicoLink", "CueRideEngine", "CueMapImport"],
            path: "ios/CuePicoLink/Tests/CuePicoLinkTests"
        ),
        // Companion to webmap.dev#227: Overpass extract -> squeeze-zone
        // overlay GeoJSON, through the same importer/scorer the app runs.
        .executableTarget(
            name: "cue-zone-export",
            dependencies: ["CueMapImport"],
            path: "tools/cue-zone-export"
        ),
        // Companion to webmap.dev#231: ride trace + latency sidecar +
        // Overpass extract -> cue-events overlay GeoJSON, resolving event
        // geometry through the same importer the app runs.
        .executableTarget(
            name: "cue-events-export",
            dependencies: ["CueMapImport"],
            path: "tools/cue-events-export"
        ),
        // Companion to webmap.dev#239: merge the map-grading UI's reviews
        // sidecar back into the ride trace's reviews[] (FR-008) — the
        // trace stays the single source of truth for replay and tuning.
        .executableTarget(
            name: "cue-review-merge",
            dependencies: ["CueMapImport"],
            path: "tools/cue-review-merge"
        ),
        // RFC 0002: desk-tool counterpart to the app's "Import custom
        // zones…" action — merge webmap.dev's custom-zones GeoJSON export
        // into a replay trace's personal_memory[] for tuning without a
        // live ride.
        .executableTarget(
            name: "cue-custom-zone-merge",
            dependencies: ["CueMapImport"],
            path: "tools/cue-custom-zone-merge"
        ),
    ]
)
