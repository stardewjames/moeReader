import Foundation

/// Estimates a release cadence from chapter dates. Sources rarely expose a
/// schedule, so this is a display hint, not a contract.
enum MihonReleaseSchedule {
    static func describe(_ chapters: [MihonChapter]) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = Set(
            chapters.compactMap(\.publishedAt).map {
                calendar.startOfDay(for: $0)
            }
        ).sorted()
        guard days.count >= 3 else { return "Unknown" }

        let intervals = zip(days.dropFirst(), days).compactMap { later, earlier -> Int? in
            let value = calendar.dateComponents([.day], from: earlier, to: later).day ?? 0
            return value > 0 ? value : nil
        }
        guard intervals.count >= 2 else { return "Unknown" }

        let median = intervals.sorted()[intervals.count / 2]
        switch median {
        case ...2: return "Daily"
        case 3...10: return "Weekly"
        case 11...20: return "Biweekly"
        case 21...45: return "Monthly"
        default: return "Irregular"
        }
    }
}
