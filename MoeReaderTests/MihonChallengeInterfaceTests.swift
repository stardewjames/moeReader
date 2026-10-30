import XCTest
@testable import MoeReader

/// The native interceptor classes the Mihon network surface exposes. The
/// transport itself applies the user agent and solves a browser check, but an
/// extension that builds a client shaped like `NetworkHelper` instantiates
/// these objects directly, so the constructors it can compile against must
/// resolve and run.
final class MihonChallengeInterfaceTests: XCTestCase {
    private func constructor(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ signature: String
    ) throws -> VMMethod {
        let cls = try runtime.linkClass(descriptor)
        return try XCTUnwrap(
            cls.lookupVirtual(key: "<init>\(signature)"),
            "missing \(descriptor) <init>\(signature)"
        )
    }

    func testPassThroughInterceptorsHaveNoArgumentConstructors() throws {
        let runtime = VMRuntime()
        for name in ["UncaughtExceptionInterceptor", "UserAgentInterceptor", "CloudflareInterceptor"] {
            let descriptor = "Leu/kanade/tachiyomi/network/interceptor/\(name);"
            let initMethod = try constructor(runtime, descriptor, "()V")
            XCTAssertEqual(try runtime.invoke(initMethod, [.null]).bits, 0)
        }
    }

    func testCloudflareInterceptorConstructorsMatchMihonShapes() throws {
        let descriptor = "Leu/kanade/tachiyomi/network/interceptor/CloudflareInterceptor;"
        let runtime = VMRuntime()
        let context = "Landroid/content/Context;"
        let cookieJar = "Lokhttp3/CookieJar;"
        let userAgent = "Lkotlin/jvm/functions/Function0;"
        let scope = "Lkotlinx/coroutines/CoroutineScope;"
        let defaults = "ILkotlin/jvm/internal/DefaultConstructorMarker;"
        let signatures = [
            "(\(context))V",
            "(\(context)\(cookieJar))V",
            "(\(context)\(cookieJar)\(userAgent))V",
            "(\(context)\(cookieJar)\(userAgent)\(defaults))V",
            "(\(context)\(cookieJar)\(scope)\(userAgent))V",
            "(\(context)\(cookieJar)\(scope)\(userAgent)\(defaults))V",
        ]
        for signature in signatures {
            let initMethod = try constructor(runtime, descriptor, signature)
            let arguments = Array(repeating: VMValue.null, count: initMethod.parameterTypes.count + 1)
            XCTAssertEqual(try runtime.invoke(initMethod, arguments).bits, 0)
        }
    }
}
