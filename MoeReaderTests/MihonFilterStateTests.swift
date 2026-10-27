import Foundation
import XCTest
@testable import MoeReader

final class MihonFilterStateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MihonFilterStateTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSelectionStoreRoundTripsValuesAndSortDirection() {
        let store = MihonFilterSelectionStore(defaults: defaults)
        let selections: [String: MihonFilterSelection] = [
            "0": MihonFilterSelection(value: "title", ascending: false),
            "1.2": MihonFilterSelection(value: "2", ascending: true)
        ]

        store.save(selections, forSourceIdentity: "en#42")

        let reloaded = MihonFilterSelectionStore(defaults: defaults)
        XCTAssertEqual(reloaded.selections(forSourceIdentity: "en#42"), selections)
    }

    func testSavingEmptySelectionClearsStoredFilters() {
        let store = MihonFilterSelectionStore(defaults: defaults)
        store.save(
            ["0": MihonFilterSelection(value: "title", ascending: false)],
            forSourceIdentity: "en#42"
        )
        XCTAssertFalse(store.selections(forSourceIdentity: "en#42").isEmpty)

        store.save([:], forSourceIdentity: "en#42")

        XCTAssertEqual(store.selections(forSourceIdentity: "en#42"), [:])
        XCTAssertEqual(
            MihonFilterSelectionStore(defaults: defaults).selections(forSourceIdentity: "en#42"),
            [:]
        )
    }

    func testEmptySelectionForUnknownIdentityLoadsEmpty() {
        let store = MihonFilterSelectionStore(defaults: defaults)

        XCTAssertEqual(store.selections(forSourceIdentity: "ja#7"), [:])
    }

    func testSelectionsAreSeparatedBySourceIdentity() {
        let store = MihonFilterSelectionStore(defaults: defaults)
        let english: [String: MihonFilterSelection] = [
            "0": MihonFilterSelection(value: "title", ascending: true)
        ]
        let japanese: [String: MihonFilterSelection] = [
            "0": MihonFilterSelection(value: "popularity", ascending: false),
            "2": MihonFilterSelection(value: "true", ascending: true)
        ]

        store.save(english, forSourceIdentity: "en#1")
        store.save(japanese, forSourceIdentity: "ja#2")

        XCTAssertEqual(store.selections(forSourceIdentity: "en#1"), english)
        XCTAssertEqual(store.selections(forSourceIdentity: "ja#2"), japanese)
        XCTAssertEqual(store.selections(forSourceIdentity: "en#2"), [:])

        store.save([:], forSourceIdentity: "en#1")

        XCTAssertEqual(store.selections(forSourceIdentity: "en#1"), [:])
        XCTAssertEqual(store.selections(forSourceIdentity: "ja#2"), japanese)
    }

    func testMangaCarriesCoverHeaders() {
        let coverURL = URL(string: "https://example.test/cover.jpg")
        let plain = MihonManga(id: "1", title: "Example", coverURL: coverURL)
        let withHeaders = MihonManga(
            id: "1",
            title: "Example",
            coverURL: coverURL,
            coverHeaders: ["Referer": "https://example.test/"]
        )

        XCTAssertEqual(plain.coverHeaders, [:])
        XCTAssertEqual(withHeaders.coverHeaders, ["Referer": "https://example.test/"])
        XCTAssertNotEqual(plain, withHeaders)
    }
}
