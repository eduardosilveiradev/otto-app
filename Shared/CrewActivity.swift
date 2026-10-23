import ActivityKit
import Foundation

/// The crew run as a Live Activity: started and updated by the app (no push on a free team),
/// drawn by the OttoWidgets extension on the Lock Screen and in the Dynamic Island.
struct CrewActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Agents working right now.
        var working: Int
        /// Who spoke last, and the first line of what they said.
        var who: String
        var line: String
        /// When this run started, for the timer.
        var since: Date
    }
}
