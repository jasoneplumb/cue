// Intent: The D5 voice path (FR-006): "unsafe here" as a Siri App Intent —
//         hands stay on bars, eyes stay up. Lands in the same
//         RideSessionController.mark() as the watch button, producing the
//         identical marker record (D5: both inputs, one record shape).
import AppIntents

struct UnsafeHereIntent: AppIntent {
    static let title: LocalizedStringResource = "Unsafe Here"
    static let description = IntentDescription(
        "Marks the current road position as unsafe during a cue ride.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let marked = RideSessionController.shared.mark()
        // §5.8: one confirmation — the dialog is Siri's audible ack.
        return .result(dialog: marked ? "Marked." : "No ride in progress.")
    }
}

struct CueAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UnsafeHereIntent(),
            phrases: ["Unsafe here in \(.applicationName)"],
            shortTitle: "Unsafe Here",
            systemImageName: "exclamationmark.triangle")
    }
}
