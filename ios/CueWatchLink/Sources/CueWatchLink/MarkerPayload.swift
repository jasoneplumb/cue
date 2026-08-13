// Intent: The watch→phone marker message (RFC 0003 D5, FR-006): the watch
//         button's "unsafe here" travels the reverse direction of the cue
//         path. The payload carries the WATCH'S wall clock at the button
//         press so a queued delivery arriving late still marks the segment
//         the rider was actually on — the phone maps the instant back to
//         its nearest recorded sample (RideEngine.mark(atTMs:)).
// Pattern: Same total encode/decode discipline as CuePayload: the phone
//          never records a marker it cannot fully validate.
public struct MarkerPayload: Equatable, Sendable {
    /// Single marker type in the MVP (schema `markers[].type`).
    public static let unsafeHere = "unsafe_here"

    public let type: String
    /// Unix epoch milliseconds of the button press on the watch.
    public let markedTsMs: UInt64

    public init(type: String = MarkerPayload.unsafeHere, markedTsMs: UInt64) {
        self.type = type
        self.markedTsMs = markedTsMs
    }

    enum Key {
        static let type = "marker_type"
        static let markedTsMs = "marked_ts_ms"
    }

    public func encoded() -> [String: Any] {
        // WCSession's wire type is plist Int; clamping cannot trap and a
        // clamped far-future timestamp is as meaningless either way.
        [Key.type: type, Key.markedTsMs: Int(clamping: markedTsMs)]
    }

    /// nil on anything missing, mistyped, out of range, or of an unknown
    /// marker type — forward compatibility by rejection, not by guessing.
    public init?(from message: [String: Any]) {
        guard let type = message[Key.type] as? String,
              type == Self.unsafeHere,
              let markedTsMs = message[Key.markedTsMs] as? Int,
              let ts = UInt64(exactly: markedTsMs) else { return nil }
        self.init(type: type, markedTsMs: ts)
    }
}
