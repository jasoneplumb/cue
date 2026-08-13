// Intent: The phone→watch ride-end control message. Ending a ride on the
//         phone (RideSessionController.stopRide) should not leave "Ride
//         mode" stranded ON over a dead ride — this tells the watch to turn
//         it off (ending its HKWorkoutSession) without the rider having to
//         reach for the watch.
// Pattern: Same total encode/decode discipline as the other payloads, tagged
//          by a control-type key like MarkerPayload's marker_type — decode
//          rejects anything that isn't exactly this control message rather
//          than guessing, so it can never be mistaken for a CuePayload (or
//          vice versa) on the shared WCSession channel.
public struct RideEndedPayload: Equatable, Sendable {
    public static let control = "ride_ended"

    public init() {}

    enum Key {
        static let control = "control_type"
    }

    public func encoded() -> [String: Any] {
        [Key.control: Self.control]
    }

    /// nil unless the message is exactly this control type — forward
    /// compatibility by rejection, not by guessing (same as MarkerPayload).
    public init?(from message: [String: Any]) {
        guard let control = message[Key.control] as? String,
              control == Self.control else { return nil }
        self.init()
    }
}
