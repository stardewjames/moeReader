import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// `android.os.ParcelFileDescriptor` opened inside the extension sandbox, and
/// the `android.graphics.pdf.PdfRenderer` constructor that consumes it.
final class MihonParcelFileDescriptorTests: XCTestCase {
    private final class Host: VMHost {
        let root: String
        init(root: String) { self.root = root }
        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            VMHTTPResponse(url: request.url, code: 404, body: Data())
        }
        func preferences() -> VMPreferences { Preferences() }
        func log(_ message: String) {}
        func extensionFileRoot() -> String { root }
    }

    private final class Preferences: VMPreferences {
        var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func int(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func stringSet(forKey key: String) -> Set<String>? { values[key] as? Set<String> }
        func setString(_ value: String, forKey key: String) { values[key] = value }
        func setBool(_ value: Bool, forKey key: String) { values[key] = value }
        func setInt(_ value: Int, forKey key: String) { values[key] = value }
        func setStringSet(_ value: Set<String>, forKey key: String) { values[key] = value }
        func allKeys() -> [String] { Array(values.keys) }
        func removeValue(forKey key: String) { values.removeValue(forKey: key) }
    }

    private let readOnly: Int32 = 0x10000000
    private let writeOnly: Int32 = 0x20000000
    private let readWrite: Int32 = 0x30000000
    private let create: Int32 = 0x08000000
    private let truncate: Int32 = 0x04000000

    private func makeRuntime() throws -> (VMRuntime, Host) {
        let host = Host(root: try TestFixtures.temporaryDirectory().path)
        // The runtime holds the host weakly, so the test keeps it alive.
        return (VMRuntime(host: host), host)
    }

    private func staticCall(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature), "\(descriptor).\(name)\(signature)")
        return try runtime.invoke(method, arguments)
    }

    private func instanceCall(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(name, signature), name + signature)
        return try runtime.invoke(method, [receiver] + arguments)
    }

    @discardableResult
    private func newInstance(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        let initializer = try XCTUnwrap(cls.lookupVirtual("<init>", signature), descriptor + signature)
        _ = try runtime.invoke(initializer, [value] + arguments)
        return value
    }

    private func javaFile(_ runtime: VMRuntime, _ path: String) throws -> VMValue {
        try newInstance(runtime, "Ljava/io/File;", "(Ljava/lang/String;)V", [runtime.newString(path)])
    }

    private func open(_ runtime: VMRuntime, _ file: VMValue, _ mode: Int32) throws -> VMValue {
        try staticCall(
            runtime,
            "Landroid/os/ParcelFileDescriptor;",
            "open",
            "(Ljava/io/File;I)Landroid/os/ParcelFileDescriptor;",
            [file, .int32(mode)]
        )
    }

    private func close(_ runtime: VMRuntime, _ descriptor: VMValue) throws {
        _ = try instanceCall(runtime, descriptor, "close", "()V")
    }

    // MARK: - ParcelFileDescriptor

    func testOpenReadOnlyLifecycleAndClosedDescriptor() throws {
        let (runtime, host) = try makeRuntime()
        let root = host.root
        let path = root + "/page.pdf"
        let bytes = Data("%PDF-1.4\n".utf8)
        try bytes.write(to: URL(fileURLWithPath: path))

        let descriptor = try open(runtime, javaFile(runtime, path), readOnly)
        XCTAssertEqual(
            try instanceCall(runtime, descriptor, "getStatSize", "()J").asInt64,
            Int64(bytes.count)
        )

        let fileDescriptor = try instanceCall(
            runtime, descriptor, "getFileDescriptor", "()Ljava/io/FileDescriptor;"
        )
        XCTAssertNotEqual(fileDescriptor.bits, 0)
        XCTAssertTrue(
            try instanceCall(runtime, fileDescriptor, "valid", "()Z").asBoolean,
            "an open descriptor is valid"
        )

        try close(runtime, descriptor)
        XCTAssertThrowsError(
            try instanceCall(runtime, descriptor, "getFileDescriptor", "()Ljava/io/FileDescriptor;")
        ) { error in
            guard let exception = error as? VMJavaException else { return XCTFail("\(error)") }
            XCTAssertEqual(exception.classDescriptor, "Ljava/io/IOException;")
            XCTAssertEqual(exception.message, "Bad file descriptor")
        }
        XCTAssertEqual(try instanceCall(runtime, descriptor, "getStatSize", "()J").asInt64, -1)
        XCTAssertFalse(try instanceCall(runtime, fileDescriptor, "valid", "()Z").asBoolean)
        // Closing twice is a no-op, as on the platform.
        try close(runtime, descriptor)
    }

    func testOpenHonoursCreateTruncateAndModeValidation() throws {
        let (runtime, host) = try makeRuntime()
        let root = host.root
        let missing = root + "/missing.bin"

        XCTAssertThrowsError(try open(runtime, javaFile(runtime, missing), writeOnly)) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/io/FileNotFoundException;")
        }

        let created = try open(
            runtime, javaFile(runtime, missing), writeOnly | create | truncate
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing))
        XCTAssertEqual(try instanceCall(runtime, created, "getStatSize", "()J").asInt64, 0)
        try close(runtime, created)

        try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: missing))
        let truncated = try open(runtime, javaFile(runtime, missing), readWrite | truncate)
        XCTAssertEqual(try instanceCall(runtime, truncated, "getStatSize", "()J").asInt64, 0)
        try close(runtime, truncated)

        // CREATE without TRUNCATE keeps existing bytes.
        try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: missing))
        let kept = try open(runtime, javaFile(runtime, missing), readOnly | create)
        XCTAssertEqual(try instanceCall(runtime, kept, "getStatSize", "()J").asInt64, 4)
        try close(runtime, kept)

        XCTAssertThrowsError(try open(runtime, javaFile(runtime, missing), 0)) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalArgumentException;")
            XCTAssertEqual((error as? VMJavaException)?.message, "Bad mode: 0")
        }
        XCTAssertThrowsError(
            try staticCall(
                runtime,
                "Landroid/os/ParcelFileDescriptor;",
                "open",
                "(Ljava/io/File;I)Landroid/os/ParcelFileDescriptor;",
                [.null, .int32(readOnly)]
            )
        ) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/NullPointerException;")
        }
    }

    func testFromFdFailsClosed() throws {
        let (runtime, _) = try makeRuntime()
        XCTAssertThrowsError(
            try staticCall(
                runtime,
                "Landroid/os/ParcelFileDescriptor;",
                "fromFd",
                "(I)Landroid/os/ParcelFileDescriptor;",
                [.int32(3)]
            )
        ) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/io/IOException;")
            XCTAssertEqual((error as? VMJavaException)?.message, "Bad file descriptor")
        }
    }

    // MARK: - PdfRenderer

    func testPdfRendererReadsParcelFileDescriptor() throws {
        let (runtime, host) = try makeRuntime()
        let root = host.root
        let path = root + "/document.pdf"
        let pdf = Self.minimalPDF()
        try pdf.write(to: URL(fileURLWithPath: path))

        let descriptor = try open(runtime, javaFile(runtime, path), readOnly)
        let renderer = try newInstance(
            runtime,
            "Landroid/graphics/pdf/PdfRenderer;",
            "(Landroid/os/ParcelFileDescriptor;)V",
            [descriptor]
        )
        XCTAssertEqual(runtime.payload(renderer, as: VMPdfRendererPayload.self)?.data, pdf)

        #if canImport(CoreGraphics)
        XCTAssertEqual(try instanceCall(runtime, renderer, "getPageCount", "()I").asInt32, 1)
        let page = try instanceCall(
            runtime, renderer, "openPage", "(I)Landroid/graphics/pdf/PdfRenderer$Page;", [.int32(0)]
        )
        XCTAssertEqual(try instanceCall(runtime, page, "getWidth", "()I").asInt32, 200)
        XCTAssertEqual(try instanceCall(runtime, page, "getHeight", "()I").asInt32, 300)
        #else
        XCTAssertThrowsError(
            try instanceCall(runtime, renderer, "getPageCount", "()I")
        ) { error in
            XCTAssertEqual(
                (error as? VMJavaException)?.classDescriptor,
                "Ljava/lang/UnsupportedOperationException;"
            )
        }
        #endif
        try close(runtime, descriptor)
    }

    func testPdfRendererRejectsClosedDescriptor() throws {
        let (runtime, host) = try makeRuntime()
        let root = host.root
        let path = root + "/document.pdf"
        try Self.minimalPDF().write(to: URL(fileURLWithPath: path))
        let descriptor = try open(runtime, javaFile(runtime, path), readOnly)
        try close(runtime, descriptor)

        XCTAssertThrowsError(
            try newInstance(
                runtime,
                "Landroid/graphics/pdf/PdfRenderer;",
                "(Landroid/os/ParcelFileDescriptor;)V",
                [descriptor]
            )
        ) { error in
            guard let exception = error as? VMJavaException else { return XCTFail("\(error)") }
            XCTAssertEqual(exception.classDescriptor, "Ljava/io/IOException;")
            XCTAssertEqual(exception.message, "PdfRenderer: cannot read the descriptor")
        }
    }

    // MARK: - Fixture

    /// One A4-ish page, with a correct cross-reference table so CoreGraphics
    /// accepts it and reports `Count 1`.
    private static func minimalPDF() -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] >>"
        ]
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            text += String(format: "%010d 00000 n \n", offset)
        }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }
}
