import Foundation

enum PageOrdering {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tif", "tiff",
    ]

    static func isImageName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasSuffix("/") else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            if component.hasPrefix(".") { return false }
            if component == "__MACOSX" { return false }
        }
        guard let last = components.last, !last.hasPrefix("._") else { return false }
        let pathExtension = (String(last) as NSString).pathExtension.lowercased()
        return imageExtensions.contains(pathExtension)
    }

    static func sortedImageNames(_ names: [String]) -> [String] {
        names.filter(isImageName).sorted(by: precedes)
    }

    /// Natural, case-insensitive ordering with a deterministic total tie-break.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let leftTokens = tokens(lhs.lowercased())
        let rightTokens = tokens(rhs.lowercased())
        var index = 0
        while index < leftTokens.count, index < rightTokens.count {
            switch compare(leftTokens[index], rightTokens[index]) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                index += 1
            }
        }
        if leftTokens.count != rightTokens.count {
            return leftTokens.count < rightTokens.count
        }
        return lhs < rhs
    }

    private enum Token {
        case digits([Unicode.Scalar])
        case text([Unicode.Scalar])
    }

    private static func tokens(_ value: String) -> [Token] {
        var result: [Token] = []
        var buffer: [Unicode.Scalar] = []
        var bufferIsDigit: Bool?

        func flush() {
            guard let isDigit = bufferIsDigit, !buffer.isEmpty else { return }
            result.append(isDigit ? .digits(buffer) : .text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        for scalar in value.unicodeScalars {
            let isDigit = scalar.properties.numericType == .decimal
            if bufferIsDigit != isDigit {
                flush()
                bufferIsDigit = isDigit
            }
            buffer.append(scalar)
        }
        flush()
        return result
    }

    private static func compare(_ lhs: Token, _ rhs: Token) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.digits(let left), .digits(let right)):
            return compareDigits(left, right)
        case (.text(let left), .text(let right)):
            return compareScalars(left, right)
        case (.digits, .text):
            return .orderedAscending
        case (.text, .digits):
            return .orderedDescending
        }
    }

    private static func compareDigits(
        _ lhs: [Unicode.Scalar],
        _ rhs: [Unicode.Scalar]
    ) -> ComparisonResult {
        let leftSignificant = lhs.drop(while: { $0.value == 0x30 })
        let rightSignificant = rhs.drop(while: { $0.value == 0x30 })
        if leftSignificant.count != rightSignificant.count {
            return leftSignificant.count < rightSignificant.count ? .orderedAscending : .orderedDescending
        }
        for (left, right) in zip(leftSignificant, rightSignificant) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func compareScalars(
        _ lhs: [Unicode.Scalar],
        _ rhs: [Unicode.Scalar]
    ) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }
}
