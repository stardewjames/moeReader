import Foundation
import XCTest
@testable import MoeReader

final class MihonCompatStoreTests: XCTestCase {
    private let indexURL = URL(string: "https://example.com/repo/index.pb")!
    private let apkURL = URL(string: "https://example.com/repo/mihon-test.apk")!

    func testAddsAndRefreshesRepository() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MihonCompatStore(
            baseDirectory: directory,
            http: makeHTTPClient(indexData: try indexData(), apkData: try apkData())
        )

        let id = try await store.addRepository(indexURL.absoluteString)
        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.repositories.count, 1)
        XCTAssertEqual(snapshot.repositories[0].id, id)
        XCTAssertEqual(snapshot.repositories[0].extensions.count, 2)
        XCTAssertEqual(snapshot.repositories[0].signingKey, "4df6ad27c7517695915334242404309f4f7d9b70689b05d7093c483c760a5e87")

        try await store.refreshRepository(id: id)
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.repositories.count, 1)
        XCTAssertEqual(snapshot.repositories[0].extensions.count, 2)
    }

    func testInstallPersistsAndUninstalls() async throws {
        #if canImport(Security)
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = makeHTTPClient(indexData: try indexData(), apkData: try apkData())
        let store = MihonCompatStore(baseDirectory: directory, http: http)
        let repositoryID = try await store.addRepository(indexURL.absoluteString)

        try await store.install(
            packageName: "com.moereader.test.extension",
            repositoryID: repositoryID
        )
        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.installed.count, 1)
        let installed = try XCTUnwrap(snapshot.installed.first)
        XCTAssertEqual(installed.packageName, "com.moereader.test.extension")
        XCTAssertEqual(installed.versionCode, 7)
        XCTAssertEqual(installed.signerSHA256, "4df6ad27c7517695915334242404309f4f7d9b70689b05d7093c483c760a5e87")
        XCTAssertTrue(installed.isEnabled)
        let apkPath = await store.apkURL(for: installed).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: apkPath))

        try await store.setEnabled(packageName: installed.packageName, isEnabled: false)
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.installed.first?.isEnabled, false)

        let reloaded = MihonCompatStore(baseDirectory: directory, http: http)
        let persisted = await reloaded.snapshot()
        XCTAssertEqual(persisted.installed.count, 1)
        XCTAssertEqual(persisted.installed.first?.apkSHA256, installed.apkSHA256)

        try await store.uninstall(packageName: installed.packageName)
        snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.installed.isEmpty)
        let removedPath = await store.apkURL(for: installed).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedPath))
        #endif
    }

    func testInstallRejectsAPKForDifferentExtension() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = makeHTTPClient(
            indexData: try indexData(),
            apkData: try Data(contentsOf: TestFixtures.url("mini", "cbz"))
        )
        let store = MihonCompatStore(baseDirectory: directory, http: http)
        let repositoryID = try await store.addRepository(indexURL.absoluteString)

        do {
            try await store.install(
                packageName: "com.moereader.test.extension",
                repositoryID: repositoryID
            )
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertTrue(
                error is MihonError || error is MihonZIPError || error is MihonInflateError,
                "unexpected error: \(error)"
            )
        }
    }

    func testInstallRequiresRepositorySigningKey() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MihonCompatStore(
            baseDirectory: directory,
            http: makeHTTPClient(indexData: try indexData(signingKey: ""), apkData: try apkData())
        )
        let repositoryID = try await store.addRepository(indexURL.absoluteString)
        do {
            try await store.install(
                packageName: "com.moereader.test.extension",
                repositoryID: repositoryID
            )
            XCTFail("Expected untrusted repository")
        } catch {
            XCTAssertEqual(error as? MihonError, .untrustedRepository)
        }
    }


    private func indexData(signingKey: String? = nil) throws -> Data {
        if signingKey == nil {
            return try Data(contentsOf: TestFixtures.url("mihon-index", "pb"))
        }
        return try Data(contentsOf: TestFixtures.url("mihon-index-nokey", "pb"))
    }

    private func apkData() throws -> Data {
        try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
    }

    private func makeHTTPClient(indexData: Data, apkData: Data) -> StubHTTPClient {
        let indexURL = self.indexURL
        let apkURL = self.apkURL
        return StubHTTPClient { request in
            let responseData: Data
            if request.url == indexURL {
                responseData = indexData
            } else if request.url == apkURL {
                responseData = apkData
            } else {
                return MihonHTTPResponse(
                    data: Data(),
                    statusCode: 404,
                    headers: [:],
                    url: request.url
                )
            }
            return MihonHTTPResponse(
                data: responseData,
                statusCode: 200,
                headers: ["content-type": "application/octet-stream"],
                url: request.url
            )
        }
    }
}
