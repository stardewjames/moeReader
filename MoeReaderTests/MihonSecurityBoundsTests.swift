import Foundation
import XCTest
@testable import MoeReader

/// Bounds tests for the extension package inspection path: malformed ZIP
/// containers and dex files must be rejected by throwing, never by trapping.
final class MihonSecurityBoundsTests: XCTestCase {
    // MARK: - ZIP

    func testZIPRejectsTooShortData() {
        XCTAssertThrowsError(try MihonZIPArchive(data: Data([0x50, 0x4b, 0x05]))) { error in
            XCTAssertEqual(error as? MihonZIPError, .notAZIPArchive)
        }
    }

    func testZIPRejectsOversizedDirectoryEntryCount() {
        // 0xFFFF is the ZIP64 sentinel: without a locator this cannot resolve.
        let data = Data(archive(directory: [], entryCount: 0xffff))
        XCTAssertThrowsError(try MihonZIPArchive(data: data)) { error in
            XCTAssertEqual(error as? MihonZIPError, .zip64)
        }
    }

    func testZIPRejectsCentralDirectoryPastEndOfFile() {
        let data = Data(archive(
            directory: [],
            entryCount: 1,
            directorySize: 46,
            directoryOffset: 22
        ))
        XCTAssertThrowsError(try MihonZIPArchive(data: data)) { error in
            XCTAssertEqual(error as? MihonZIPError, .truncated)
        }
    }

    func testZIPRejectsEntryNamePastCentralDirectory() {
        let entry = centralHeader(nameLength: 1_000)
        let data = Data(archive(directory: entry, entryCount: 1))
        XCTAssertThrowsError(try MihonZIPArchive(data: data)) { error in
            XCTAssertEqual(error as? MihonZIPError, .truncated)
        }
    }

    func testZIPRejectsEntryWhoseUncompressedSizeIsHuge() throws {
        let entry = centralHeader(
            nameLength: 1,
            compressed: 1,
            uncompressed: 0xffff_fff0,
            localOffset: 0
        )
        var directory = entry
        directory.append(0x61) // "a"

        var prefix = localHeader(nameLength: 1, compressed: 1, uncompressed: 1)
        prefix.append(0x61) // name
        prefix.append(0x00) // one-byte stored payload

        let data = Data(archive(prefix: prefix, directory: directory, entryCount: 1))
        let zip = try MihonZIPArchive(data: data)
        XCTAssertThrowsError(try zip.data(for: "a")) { error in
            guard case .entryTooLarge = error as? MihonZIPError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testZIP64HugeDirectorySizeThrowsInsteadOfTrapping() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: zip64Record(
            entryCount: 1,
            directorySize: 0xffff_ffff_ffff_ffff,
            directoryOffset: 0
        ))
        bytes.append(contentsOf: zip64Locator(recordOffset: 0))
        bytes.append(contentsOf: eocd(
            entryCount: 0xffff,
            directorySize: 0xffff_ffff,
            directoryOffset: 0xffff_ffff
        ))

        XCTAssertThrowsError(try MihonZIPArchive(data: Data(bytes))) { error in
            XCTAssertEqual(error as? MihonZIPError, .zip64)
        }
    }

    func testZIP64HugeEntryOffsetThrowsInsteadOfTrapping() {
        var extra: [UInt8] = []
        appendU16(&extra, 0x0001) // ZIP64 extended information
        appendU16(&extra, 8)      // only localOffset is sentinel
        appendU64(&extra, 0xffff_ffff_ffff_ffff)

        var directory = centralHeader(
            nameLength: 1,
            extraLength: UInt16(extra.count),
            compressed: 1,
            uncompressed: 1,
            localOffset: 0xffff_ffff
        )
        directory.append(0x61)
        directory.append(contentsOf: extra)

        let data = Data(archive(directory: directory, entryCount: 1))
        XCTAssertThrowsError(try MihonZIPArchive(data: data)) { error in
            XCTAssertEqual(error as? MihonZIPError, .zip64)
        }
    }

    // MARK: - DEX

    func testDexRejectsTruncatedHeader() {
        XCTAssertThrowsError(try DexFile(data: Data(repeating: 0, count: 16)))
    }

    func testDexRejectsStringTableLargerThanFile() {
        // A lying header used to trigger a multi-gigabyte reserveCapacity.
        var dex = DexBytes()
        dex.setU32(0x38, 0xffff_ffff) // string_ids_size
        dex.setU32(0x3c, 0x70)        // string_ids_off
        XCTAssertThrowsError(try DexFile(data: dex.data))
    }

    func testDexRejectsStringOffsetPastEnd() {
        let dex = minimalDex(classData: [0x00, 0x00, 0x00, 0x00])
        var bytes = dex
        bytes.setU32(0x70, 0xffff_fff0) // string_ids[0] -> past end
        XCTAssertThrowsError(try DexFile(data: bytes.data))
    }

    func testDexRejectsHugeClassDataCounts() {
        let dex = minimalDex(classData: [0x7f, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try DexFile(data: dex.data))
    }

    func testDexRejectsTruncatedClassData() {
        let dex = minimalDex(classData: [0x80]) // unterminated uleb128
        XCTAssertThrowsError(try DexFile(data: dex.data))
    }

    func testDexRejectsClassDataOffsetPastEnd() {
        var dex = minimalDex(classData: [0x00, 0x00, 0x00, 0x00])
        dex.setU32(0x90, 0xffff_fff0)
        XCTAssertThrowsError(try DexFile(data: dex.data))
    }

    func testDexAcceptsMinimalWellFormedClassData() throws {
        let dex = minimalDex(classData: [0x00, 0x00, 0x00, 0x00])

        let file = try DexFile(data: dex.data)
        XCTAssertTrue(file.hasClass("Lx;"))
        let definition = file.classDefNamed("Lx;")
        XCTAssertNotNil(definition)
        XCTAssertTrue(definition?.staticFields.isEmpty ?? false)
        XCTAssertTrue(definition?.directMethods.isEmpty ?? false)
    }

    // MARK: - Store rollback

    func testRemoveRepositoryRollsBackWhenPersistFails() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        try seed(repositories: [repository], installed: [], in: directory)

        let store = failingStore(at: directory)
        let before = await store.snapshot()
        do {
            try await store.removeRepository(id: repository.id)
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertTrue(error is PersistFailure)
        }
        let after = await store.snapshot()
        XCTAssertEqual(after.repositories, before.repositories)
        XCTAssertEqual(after.installed, before.installed)
    }

    func testRefreshRepositoryRollsBackWhenPersistFails() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository(signingKey: Self.fixtureSigningKey)
        try seed(repositories: [repository], installed: [], in: directory)
        let indexData = try Data(contentsOf: TestFixtures.url("mihon-index", "pb"))
        let store = MihonCompatStore(
            baseDirectory: directory,
            http: StubHTTPClient { request in
                MihonHTTPResponse(
                    data: indexData,
                    statusCode: 200,
                    headers: ["content-type": "application/octet-stream"],
                    url: request.url
                )
            },
            persistHook: { _ in throw PersistFailure() }
        )

        let before = await store.snapshot()
        do {
            try await store.refreshRepository(id: repository.id)
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertTrue(error is PersistFailure)
        }
        let after = await store.snapshot()
        XCTAssertEqual(after.repositories, before.repositories)
        XCTAssertEqual(after.installed, before.installed)
    }

    func testUninstallRollsBackRecordAndAPKWhenPersistFails() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        let installed = makeInstalled(packageName: "com.example.test", apkFileName: "one.apk")
        try seed(repositories: [repository], installed: [installed], in: directory)
        try writeAPK(named: installed.apkFileName, in: directory)

        let store = failingStore(at: directory)
        do {
            try await store.uninstall(packageName: installed.packageName)
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertTrue(error is PersistFailure)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.installed, [installed])
        XCTAssertTrue(apkExists(installed, in: directory))
    }

    func testUninstallKeepsAPKReferencedByAnotherRecord() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository()
        let first = makeInstalled(packageName: "com.example.first", apkFileName: "shared.apk")
        let second = makeInstalled(packageName: "com.example.second", apkFileName: "shared.apk")
        try seed(repositories: [repository], installed: [first, second], in: directory)
        try writeAPK(named: "shared.apk", in: directory)

        let store = MihonCompatStore(
            baseDirectory: directory,
            http: unreachableHTTP,
            persistHook: nil
        )
        try await store.uninstall(packageName: first.packageName)
        XCTAssertTrue(apkExists(second, in: directory))

        try await store.uninstall(packageName: second.packageName)
        XCTAssertFalse(apkExists(second, in: directory))
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.installed.isEmpty)
    }

    #if canImport(Security)
    func testInstallRollsBackAPKAndRecordWhenPersistFails() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let apkURL = URL(string: "https://example.test/repo/mihon-test.apk")!
        let extensionValue = MihonExtension(
            name: "Test Source",
            packageName: "com.moereader.test.extension",
            apkURL: apkURL,
            extensionLib: "1.6",
            versionCode: 7,
            versionName: "1.0.0",
            contentWarning: .mixed,
            sources: []
        )
        let repository = makeRepository(
            signingKey: Self.fixtureSigningKey,
            extensions: [extensionValue]
        )
        try seed(repositories: [repository], installed: [], in: directory)

        let apkData = try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
        let store = MihonCompatStore(
            baseDirectory: directory,
            http: StubHTTPClient { request in
                MihonHTTPResponse(
                    data: request.url == apkURL ? apkData : Data(),
                    statusCode: request.url == apkURL ? 200 : 404,
                    headers: ["content-type": "application/octet-stream"],
                    url: request.url
                )
            },
            persistHook: { _ in throw PersistFailure() }
        )

        do {
            try await store.install(
                packageName: extensionValue.packageName,
                repositoryID: repository.id
            )
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertTrue(error is PersistFailure)
        }

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.installed.isEmpty)
        let extensionsDirectory = directory.appendingPathComponent("Extensions", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: extensionsDirectory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "orphaned APK files: \(leftovers)")
    }
    #endif

    // MARK: - Fixtures

    private static let fixtureSigningKey =
        "4df6ad27c7517695915334242404309f4f7d9b70689b05d7093c483c760a5e87"

    private struct PersistFailure: Error {}

    private var unreachableHTTP: StubHTTPClient {
        StubHTTPClient { request in
            MihonHTTPResponse(data: Data(), statusCode: 500, headers: [:], url: request.url)
        }
    }

    private func failingStore(at directory: URL) -> MihonCompatStore {
        MihonCompatStore(
            baseDirectory: directory,
            http: unreachableHTTP,
            persistHook: { _ in throw PersistFailure() }
        )
    }

    private func makeRepository(
        signingKey: String = String(repeating: "a", count: 64),
        extensions: [MihonExtension] = []
    ) -> MihonRepository {
        MihonRepository(
            indexURL: URL(string: "https://example.test/repo/index.pb")!,
            name: "Test Repo",
            badgeLabel: "TEST",
            signingKey: signingKey,
            extensions: extensions
        )
    }

    private func makeInstalled(packageName: String, apkFileName: String) -> MihonInstalledExtension {
        MihonInstalledExtension(
            packageName: packageName,
            repositoryID: UUID(),
            name: packageName,
            versionCode: 1,
            versionName: "1.0",
            extensionLib: "1.6",
            contentWarning: .safe,
            apkFileName: apkFileName,
            apkSHA256: String(repeating: "b", count: 64),
            signerSHA256: String(repeating: "c", count: 64),
            installedAt: Date(timeIntervalSince1970: 0),
            isEnabled: true,
            sources: []
        )
    }

    private func seed(
        repositories: [MihonRepository],
        installed: [MihonInstalledExtension],
        in directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(repositories)
            .write(to: directory.appendingPathComponent("repositories.json"))
        try encoder.encode(installed)
            .write(to: directory.appendingPathComponent("installed.json"))
    }

    private func writeAPK(named fileName: String, in directory: URL) throws {
        let extensions = directory.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try Data([0x50, 0x4b]).write(to: extensions.appendingPathComponent(fileName))
    }

    private func apkExists(_ installed: MihonInstalledExtension, in directory: URL) -> Bool {
        let url = directory
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(installed.apkFileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - ZIP byte builders

    private func archive(
        prefix: [UInt8] = [],
        directory: [UInt8],
        entryCount: UInt16,
        directorySize: UInt32? = nil,
        directoryOffset: UInt32? = nil
    ) -> [UInt8] {
        var bytes = prefix + directory
        bytes.append(contentsOf: eocd(
            entryCount: entryCount,
            directorySize: directorySize ?? UInt32(directory.count),
            directoryOffset: directoryOffset ?? UInt32(prefix.count)
        ))
        return bytes
    }

    private func eocd(
        entryCount: UInt16,
        directorySize: UInt32,
        directoryOffset: UInt32,
        commentLength: UInt16 = 0
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        appendU32(&bytes, 0x0605_4b50)
        appendU16(&bytes, 0)
        appendU16(&bytes, 0)
        appendU16(&bytes, entryCount)
        appendU16(&bytes, entryCount)
        appendU32(&bytes, directorySize)
        appendU32(&bytes, directoryOffset)
        appendU16(&bytes, commentLength)
        return bytes
    }

    private func zip64Record(
        entryCount: UInt64,
        directorySize: UInt64,
        directoryOffset: UInt64
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        appendU32(&bytes, 0x0606_4b50)
        appendU64(&bytes, 44) // size of the remaining record
        appendU16(&bytes, 45) // version made by
        appendU16(&bytes, 45) // version needed
        appendU32(&bytes, 0)
        appendU32(&bytes, 0)
        appendU64(&bytes, entryCount)
        appendU64(&bytes, entryCount)
        appendU64(&bytes, directorySize)
        appendU64(&bytes, directoryOffset)
        return bytes
    }

    private func zip64Locator(recordOffset: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        appendU32(&bytes, 0x0706_4b50)
        appendU32(&bytes, 0)
        appendU64(&bytes, recordOffset)
        appendU32(&bytes, 1)
        return bytes
    }

    private func centralHeader(
        nameLength: UInt16,
        extraLength: UInt16 = 0,
        commentLength: UInt16 = 0,
        flags: UInt16 = 0,
        method: UInt16 = 0,
        compressed: UInt32 = 0,
        uncompressed: UInt32 = 0,
        localOffset: UInt32 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 46)
        writeU32(&bytes, 0, 0x0201_4b50)
        writeU16(&bytes, 8, flags)
        writeU16(&bytes, 10, method)
        writeU32(&bytes, 20, compressed)
        writeU32(&bytes, 24, uncompressed)
        writeU16(&bytes, 28, nameLength)
        writeU16(&bytes, 30, extraLength)
        writeU16(&bytes, 32, commentLength)
        writeU32(&bytes, 42, localOffset)
        return bytes
    }

    private func localHeader(
        nameLength: UInt16,
        extraLength: UInt16 = 0,
        compressed: UInt32 = 0,
        uncompressed: UInt32 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 30)
        writeU32(&bytes, 0, 0x0403_4b50)
        writeU16(&bytes, 8, 0)
        writeU16(&bytes, 10, 0)
        writeU32(&bytes, 18, compressed)
        writeU32(&bytes, 22, uncompressed)
        writeU16(&bytes, 26, nameLength)
        writeU16(&bytes, 28, extraLength)
        return bytes
    }

    private func appendU16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendU32(_ bytes: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private func appendU64(_ bytes: inout [UInt8], _ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private func writeU16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes[offset + shift / 8] = UInt8(truncatingIfNeeded: value >> UInt32(shift))
        }
    }

    // MARK: - DEX byte builder

    /// One class, one type (`Lx;`), no fields or methods. `classData` is
    /// appended at 0x9d and referenced by the class definition.
    private func minimalDex(classData: [UInt8]) -> DexBytes {
        var dex = DexBytes()
        dex.setU32(0x38, 1)           // string_ids_size
        dex.setU32(0x3c, 0x70)        // string_ids_off
        dex.setU32(0x40, 1)           // type_ids_size
        dex.setU32(0x44, 0x74)        // type_ids_off
        dex.setU32(0x60, 1)           // class_defs_size
        dex.setU32(0x64, 0x78)        // class_defs_off

        dex.extend(to: 0x9d)
        dex.setU32(0x70, 0x98)        // string data offset
        dex.setU32(0x74, 0)           // type 0 -> string 0
        dex.setU32(0x78, 0)           // class_idx
        dex.setU32(0x80, 0xffff_ffff)// superclass_idx = none
        dex.setU32(0x88, 0xffff_ffff)// source_file_idx = none
        dex.setU32(0x90, 0x9d)        // class_data_off
        dex.bytes[0x98] = 0x03        // string_data_item: utf16 length 3
        dex.bytes[0x99] = 0x4c        // 'L'
        dex.bytes[0x9a] = 0x78        // 'x'
        dex.bytes[0x9b] = 0x3b        // ';'
        dex.bytes[0x9c] = 0x00        // terminator
        dex.bytes.append(contentsOf: classData)
        return dex
    }

    private struct DexBytes {
        var bytes: [UInt8]

        init() {
            bytes = [UInt8](repeating: 0, count: 0x70)
            bytes[0] = 0x64 // 'd'
            bytes[1] = 0x65 // 'e'
            bytes[2] = 0x78 // 'x'
            bytes[3] = 0x0a // '\n'
            bytes[4] = 0x30 // '0'
            bytes[5] = 0x33 // '3'
            bytes[6] = 0x35 // '5'
            bytes[7] = 0x00
            setU32(0x24, 0x70)        // header_size
            setU32(0x28, 0x1234_5678) // endian_tag
        }

        var data: Data {
            Data(bytes)
        }

        mutating func extend(to newCount: Int) {
            if bytes.count < newCount {
                bytes.append(contentsOf: [UInt8](repeating: 0, count: newCount - bytes.count))
            }
        }

        mutating func setU32(_ offset: Int, _ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                bytes[offset + shift / 8] = UInt8(truncatingIfNeeded: value >> UInt32(shift))
            }
        }
    }
}
