import Foundation

enum TapZoneLayout: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case off
    case sides
    case sidesReversed
    case topBottom
    case bottomTop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .sides:
            return "Sides"
        case .sidesReversed:
            return "Sides (reversed)"
        case .topBottom:
            return "Top / Bottom"
        case .bottomTop:
            return "Bottom / Top"
        }
    }

    var summary: String {
        switch self {
        case .off:
            return "A single tap toggles the reader controls."
        case .sides:
            return "Tap the left or right third to turn pages following the reading direction; tap the center for controls."
        case .sidesReversed:
            return "Same side zones with the page-turn directions swapped."
        case .topBottom:
            return "Tap the top third for the previous page and the bottom third for the next page; tap the middle for controls."
        case .bottomTop:
            return "Same top and bottom zones with the page-turn directions swapped."
        }
    }
}

enum ReaderTapAction: Equatable, Sendable {
    case previousPage
    case nextPage
    case toggleChrome
}
