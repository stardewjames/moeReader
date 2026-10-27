import Foundation
import XCTest
@testable import MoeReader

final class MihonIndexDecoderTests: XCTestCase {
    private let indexURL = URL(string: "https://example.com/repo/index.pb")!

    func testDecodesGzippedProtobufIndex() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-index", "pb"))
        let index = try MihonIndexDecoder.decode(data, indexURL: indexURL)

        XCTAssertEqual(index.name, "MoeReader Test Repo")
        XCTAssertEqual(index.badgeLabel, "TEST")
        XCTAssertEqual(index.signingKey, "4df6ad27c7517695915334242404309f4f7d9b70689b05d7093c483c760a5e87")
        XCTAssertEqual(index.contact?.website, "https://example.com")
        XCTAssertEqual(index.contact?.discord, "https://discord.gg/example")
        XCTAssertEqual(index.extensions.count, 2)

        let extensionValue = try XCTUnwrap(index.extensions.first)
        XCTAssertEqual(extensionValue.name, "Test Source")
        XCTAssertEqual(extensionValue.packageName, "com.moereader.test.extension")
        XCTAssertEqual(extensionValue.apkURL.absoluteString, "https://example.com/repo/mihon-test.apk")
        XCTAssertEqual(extensionValue.extensionLib, "1.6")
        XCTAssertEqual(extensionValue.versionCode, 7)
        XCTAssertEqual(extensionValue.versionName, "1.0.0")
        XCTAssertEqual(extensionValue.contentWarning, .mixed)
        XCTAssertEqual(extensionValue.sources.count, 1)
        XCTAssertEqual(extensionValue.sources[0].id, 12_345)
        XCTAssertEqual(extensionValue.sources[0].language, "en")
        XCTAssertEqual(extensionValue.sources[0].homeURL.absoluteString, "https://example.com")
        XCTAssertEqual(extensionValue.sources[0].mirrorURLs.map(\.absoluteString), ["https://mirror.example.com"])
        XCTAssertEqual(extensionValue.sources[0].message, "hello")

        let second = index.extensions[1]
        XCTAssertEqual(second.contentWarning, .nsfw)
        XCTAssertTrue(second.sources.isEmpty)
    }

    func testDecodesRawProtobufIndex() throws {
        let gzipped = try Data(contentsOf: TestFixtures.url("mihon-index", "pb"))
        let raw = try Data(contentsOf: TestFixtures.url("mihon-index-raw", "pb"))
        let expected = try MihonIndexDecoder.decode(gzipped, indexURL: indexURL)
        let decoded = try MihonIndexDecoder.decode(raw, indexURL: indexURL)
        XCTAssertEqual(decoded.name, expected.name)
        XCTAssertEqual(decoded.extensions.map(\.packageName), expected.extensions.map(\.packageName))
    }

    func testDecodesLegacyJSONIndex() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-index", "json"))
        let index = try MihonIndexDecoder.decode(
            data,
            indexURL: URL(string: "https://example.com/repo/index.min.json")!
        )
        XCTAssertEqual(index.extensions.count, 1)
        let extensionValue = try XCTUnwrap(index.extensions.first)
        XCTAssertEqual(extensionValue.packageName, "com.example.json")
        XCTAssertEqual(extensionValue.contentWarning, .nsfw)
        XCTAssertEqual(extensionValue.sources.first?.id, 98_765)
        XCTAssertEqual(extensionValue.sources.first?.language, "ja")
    }

    func testJSONRelativeAPKResolvesAgainstIndex() throws {
        let json = """
        [{"name":"Relative","pkg":"com.example.relative","apk":"pkg.apk",
          "sources":[{"name":"Relative","lang":"en","id":"1","baseUrl":"https://relative.example"}]}]
        """.data(using: .utf8)!
        let index = try MihonIndexDecoder.decode(
            json,
            indexURL: URL(string: "https://example.com/repo/index.min.json")!
        )
        XCTAssertEqual(
            index.extensions.first?.apkURL.absoluteString,
            "https://example.com/repo/pkg.apk"
        )
    }

    func testRejectsMalformedIndex() {
        XCTAssertThrowsError(
            try MihonIndexDecoder.decode(Data([0x0a, 0xff]), indexURL: indexURL)
        )
    }


    func testFollowsExtensionListURL() async throws {
        let indexJSON = """
        {"name":"Split Repo","signingKey":"\(String(repeating: "a", count: 64))",
         "extensionListUrl":"list.json"}
        """.data(using: .utf8)!
        let listJSON = try Data(contentsOf: TestFixtures.url("mihon-index", "json"))
        let indexURL = URL(string: "https://example.com/repo/index.pb")!
        let listURL = URL(string: "https://example.com/repo/list.json")!
        let service = MihonRepositoryService(http: StubHTTPClient { request in
            let data = request.url == indexURL ? indexJSON : (request.url == listURL ? listJSON : Data())
            return MihonHTTPResponse(
                data: data,
                statusCode: request.url == indexURL || request.url == listURL ? 200 : 404,
                headers: [:],
                url: request.url
            )
        })
        let fetched = try await service.fetchIndex(at: indexURL)
        XCTAssertEqual(fetched.index.name, "Split Repo")
        XCTAssertEqual(fetched.index.extensions.count, 1)
        XCTAssertEqual(fetched.index.extensions.first?.packageName, "com.example.json")
    }

    func testConditionalFetchReturnsUnchanged() async throws {
        let indexURL = URL(string: "https://example.com/repo/index.pb")!
        let service = MihonRepositoryService(http: StubHTTPClient { request in
            XCTAssertEqual(request.headers["If-None-Match"], "etag-1")
            return MihonHTTPResponse(
                data: Data(),
                statusCode: 304,
                headers: ["etag": "etag-1"],
                url: request.url
            )
        })
        let fetched = try await service.fetchIndex(at: indexURL, etag: "etag-1")
        XCTAssertTrue(fetched.unchanged)
        XCTAssertTrue(fetched.index.extensions.isEmpty)
    }

    func testRepositoryURLNormalization() throws {
        let service = MihonRepositoryService(http: StubHTTPClient { request in
            MihonHTTPResponse(
                data: Data(),
                statusCode: 500,
                headers: [:],
                url: request.url
            )
        })
        XCTAssertEqual(
            try service.normalizeIndexURL("https://example.com/extensions").absoluteString,
            "https://example.com/extensions/index.pb"
        )
        XCTAssertEqual(
            try service.normalizeIndexURL("https://example.com/repo/index.min.json").absoluteString,
            "https://example.com/repo/index.min.json"
        )
        XCTAssertThrowsError(try service.normalizeIndexURL("ftp://example.com/repo"))
    }
}

struct StubHTTPClient: MihonHTTPFetching {
    let handler: @Sendable (MihonHTTPRequest) async throws -> MihonHTTPResponse

    init(handler: @escaping @Sendable (MihonHTTPRequest) async throws -> MihonHTTPResponse) {
        self.handler = handler
    }

    func fetch(_ request: MihonHTTPRequest) async throws -> MihonHTTPResponse {
        try await handler(request)
    }
}
