// Intent: The running build's identity for the UI (#107, #137): bare
//         semver from MARKETING_VERSION, read from the bundle so
//         `/release` bumps propagate with no code change. The "-alpha"
//         postfix and build number stay in the bundle metadata — they
//         are release/engineering identity, not UI chrome.
// Pattern: Duplicated verbatim in ios/CueWatch/AppVersion.swift — the two
//          app targets share no app-layer package, and the watch-link
//          package is the wrong home for UI chrome. Keep the copies
//          identical.
import Foundation

enum AppVersion {
    /// e.g. "cue 0.1.0" — "?" only if the bundle is malformed.
    /// `let`: fixed at launch; computed once, not per render pass.
    static let line: String = {
        let marketing = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let semver = marketing?
            .split(separator: "-", maxSplits: 1)
            .first.map(String.init) ?? "?"
        return "cue \(semver)"
    }()
}
