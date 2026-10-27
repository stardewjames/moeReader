import CoreGraphics
import Foundation

enum ReadingMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case pagedLeftToRight
    case pagedRightToLeft
    case pagedVertical
    case longStrip
    case longStripWithGaps
    case defaultMode = "default"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pagedLeftToRight:
            return "Paged (left to right)"
        case .pagedRightToLeft:
            return "Paged (right to left)"
        case .pagedVertical:
            return "Paged (vertical)"
        case .longStrip:
            return "Long strip"
        case .longStripWithGaps:
            return "Long strip with gaps"
        case .defaultMode:
            return "Default"
        }
    }

    /// Human-readable behavior, used for accessibility hints.
    var summary: String {
        switch self {
        case .pagedLeftToRight:
            return "Individual pages with horizontal navigation from left to right."
        case .pagedRightToLeft:
            return "Individual pages with horizontal navigation from right to left, as in traditional manga."
        case .pagedVertical:
            return "Individual pages with vertical navigation, one page at a time."
        case .longStrip:
            return "Pages in a continuous vertical strip without gaps, ideal for webtoons."
        case .longStripWithGaps:
            return "Pages in a continuous vertical scroll with separation between pages."
        case .defaultMode:
            return "Use the configured default reading mode instead of overriding it for this series."
        }
    }

    /// Concrete modes that can be configured as an app default.
    static var concreteCases: [ReadingMode] {
        allCases.filter { $0 != .defaultMode }
    }

    var isLongStrip: Bool {
        self == .longStrip || self == .longStripWithGaps
    }

    var isVerticalPaging: Bool {
        self == .pagedVertical
    }

    var reversesPageOrder: Bool {
        self == .pagedRightToLeft
    }

    /// Vertical gap between pages in long-strip mode; zero means gap-free.
    var stripSpacing: CGFloat {
        self == .longStripWithGaps ? 16 : 0
    }

    func resolved(using defaultMode: ReadingMode) -> ReadingMode {
        guard self == .defaultMode else { return self }
        return defaultMode == .defaultMode ? .pagedRightToLeft : defaultMode
    }
}
