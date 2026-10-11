import Foundation

/// The kill switch as the helper reports it (`ks state`).
enum Protection: Equatable {
    case unknown
    case notInstalled
    case on
    case off
    case paused(until: Date)

    var isPaused: Bool { if case .paused = self { true } else { false } }

    /// Format stored for the widget.
    var stored: String {
        switch self {
        case .on: "on"
        case .off, .unknown: "off"
        case .paused(let until): "paused:\(Int(until.timeIntervalSince1970))"
        case .notInstalled: "notInstalled"
        }
    }
}
