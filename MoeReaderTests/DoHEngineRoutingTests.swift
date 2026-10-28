import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// The switch itself: with "Encrypted DNS" on, the engine host and the app's
/// HTTP client must take the pinned route. On a host without `Network` that
/// route fails closed with a typed error, which is exactly what these tests
/// assert; on Apple platforms the same wiring runs with the real transport.
final class DoHEngineRoutingTests: XCTestCase {
    /// Turns the setting on and returns the restore step. The choice lives in
    /// standard defaults because that is what the engine and the HTTP client
    /// read at request time.
    private func enableEncryptedDNS() -> () -> Void {
        let defaults = UserDefaults.standard
        let previousEnabled = defaults.object(forKey: DoHConfiguration.enabledKey)
        let previousProvider = defaults.object(forKey: DoHConfiguration.providerKey)
        let previousCustom = defaults.object(forKey: DoHConfiguration.customEndpointKey)
        DoHConfiguration(enabled: true, provider: .cloudflare).save(to: defaults)
        return {
            for (key, value) in [
                (DoHConfiguration.enabledKey, previousEnabled),
                (DoHConfiguration.providerKey, previousProvider),
                (DoHConfiguration.customEndpointKey, previousCustom),
            ] {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    func testEngineHostRoutesThroughPinnedTransportWhenEnabled() throws {
        #if !canImport(Network)
        let restore = enableEncryptedDNS()
        defer { restore() }

        let host = MihonEngineHost(prefix: "doh-routing-\(UUID().uuidString)") { _ in }
        let request = VMHTTPRequest(url: "https://example.com/", method: "GET")
        XCTAssertThrowsError(try host.performRequest(request)) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(exception.classDescriptor, "Ljava/io/IOException;")
            XCTAssertTrue(
                exception.message?.contains("encrypted DNS transport") == true,
                exception.message ?? ""
            )
        }
        #endif
    }

    func testHTTPClientRoutesThroughPinnedTransportWhenEnabled() async throws {
        #if !canImport(Network)
        let restore = enableEncryptedDNS()
        defer { restore() }

        let client = MihonHTTPClient()
        let request = MihonHTTPRequest(url: URL(string: "https://example.com/")!)
        do {
            _ = try await client.fetch(request)
            XCTFail("the pinned route must not fall back to the system resolver")
        } catch let error as MihonError {
            guard case .network(let message) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("Network framework is not available"), message)
        }
        #endif
    }
}
