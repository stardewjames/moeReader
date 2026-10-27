import Foundation
import XCTest

enum TestFixtures {
    static func url(
        _ name: String,
        _ ext: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL {
        let bundle = Bundle(for: BundleToken.self)
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        XCTFail("Missing fixture \(name).\(ext) in \(bundle.bundlePath)", file: file, line: line)
        return URL(fileURLWithPath: "/nonexistent/\(name).\(ext)")
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoeReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class BundleToken {}
