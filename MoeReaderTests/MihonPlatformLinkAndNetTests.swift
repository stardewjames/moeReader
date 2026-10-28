import XCTest
@testable import MoeReader

/// Portable coverage for the android.text span/`Linkify` surface and the
/// `java.net` address/URI helpers the whole-index audit found missing.
final class MihonPlatformLinkAndNetTests: XCTestCase {
    private func runtime() -> VMRuntime {
        VMRuntime()
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
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key), key)
        return try runtime.invoke(method, [receiver] + arguments)
    }

    @discardableResult
    private func newInstance(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        _ = try instanceCall(runtime, value, key, arguments)
        return value
    }

    private func text(_ runtime: VMRuntime, _ value: VMValue) -> String? {
        guard let string = try? instanceCall(runtime, value, "toString()Ljava/lang/String;") else { return nil }
        return runtime.stringValue(string)
    }

    private func spannable(_ runtime: VMRuntime, _ value: String) throws -> VMValue {
        try newInstance(
            runtime,
            "Landroid/text/SpannableString;",
            "<init>(Ljava/lang/CharSequence;)V",
            [runtime.newString(value)]
        )
    }

    private func classValue(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        runtime.classObject(try runtime.linkClass(descriptor))
    }

    private func uri(_ runtime: VMRuntime, _ value: String) throws -> VMValue {
        try newInstance(runtime, "Ljava/net/URI;", "<init>(Ljava/lang/String;)V", [runtime.newString(value)])
    }

    // MARK: - SpannableString

    func testSpannableStringAnswersCharSequenceAndSubSequence() throws {
        let runtime = runtime()
        let value = try spannable(runtime, "visit example.com now")
        XCTAssertEqual(try instanceCall(runtime, value, "length()I").asInt32, 21)
        XCTAssertEqual(try instanceCall(runtime, value, "charAt(I)C", [.int32(0)]).asInt32, 118)
        XCTAssertEqual(try instanceCall(runtime, value, "charAt(I)C", [.int32(6)]).asInt32, 101)
        XCTAssertEqual(text(runtime, value), "visit example.com now")

        let sub = try instanceCall(
            runtime, value, "subSequence(II)Ljava/lang/CharSequence;", [.int32(0), .int32(5)]
        )
        XCTAssertEqual(runtime.classOf(sub)?.descriptor, "Landroid/text/SpannableString;")
        XCTAssertEqual(text(runtime, sub), "visit")

        XCTAssertThrowsError(try instanceCall(runtime, value, "charAt(I)C", [.int32(21)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/StringIndexOutOfBoundsException;")
        }
        XCTAssertThrowsError(try instanceCall(runtime, value, "subSequence(II)Ljava/lang/CharSequence;", [.int32(4), .int32(2)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IndexOutOfBoundsException;")
        }
    }

    func testSpannableStringRecordsSpansForQueries() throws {
        let runtime = runtime()
        let value = try spannable(runtime, "visit example.com now")
        let span = try newInstance(
            runtime, "Landroid/text/style/URLSpan;", "<init>(Ljava/lang/String;)V",
            [runtime.newString("https://example.com")]
        )
        try instanceCall(runtime, value, "setSpan(Ljava/lang/Object;IIII)V", [span, .int32(6), .int32(17), .int32(33)])

        XCTAssertEqual(try instanceCall(runtime, value, "getSpanStart(Ljava/lang/Object;)I", [span]).asInt32, 6)
        XCTAssertEqual(try instanceCall(runtime, value, "getSpanEnd(Ljava/lang/Object;)I", [span]).asInt32, 17)
        XCTAssertEqual(try instanceCall(runtime, value, "getSpanFlags(Ljava/lang/Object;)I", [span]).asInt32, 33)

        let urlSpans = try instanceCall(
            runtime, value, "getSpans(IILjava/lang/Class;)[Ljava/lang/Object;",
            [.int32(0), .int32(20), try classValue(runtime, "Landroid/text/style/URLSpan;")]
        )
        XCTAssertEqual(runtime.arrayLength(urlSpans), 1)
        XCTAssertEqual(runtime.arrayElement(urlSpans, 0).bits, span.bits)

        let strings = try instanceCall(
            runtime, value, "getSpans(IILjava/lang/Class;)[Ljava/lang/Object;",
            [.int32(0), .int32(20), try classValue(runtime, "Ljava/lang/String;")]
        )
        XCTAssertEqual(runtime.arrayLength(strings), 0)

        // A point query inside the span sees it; outside it does not.
        let inside = try instanceCall(
            runtime, value, "getSpans(IILjava/lang/Class;)[Ljava/lang/Object;",
            [.int32(10), .int32(10), try classValue(runtime, "Landroid/text/style/URLSpan;")]
        )
        XCTAssertEqual(runtime.arrayLength(inside), 1)
        let outside = try instanceCall(
            runtime, value, "getSpans(IILjava/lang/Class;)[Ljava/lang/Object;",
            [.int32(2), .int32(2), try classValue(runtime, "Landroid/text/style/URLSpan;")]
        )
        XCTAssertEqual(runtime.arrayLength(outside), 0)

        try instanceCall(runtime, value, "removeSpan(Ljava/lang/Object;)V", [span])
        XCTAssertEqual(try instanceCall(runtime, value, "getSpanStart(Ljava/lang/Object;)I", [span]).asInt32, -1)
        let remaining = try instanceCall(
            runtime, value, "getSpans(IILjava/lang/Class;)[Ljava/lang/Object;",
            [.int32(0), .int32(20), try classValue(runtime, "Ljava/lang/Object;")]
        )
        XCTAssertEqual(runtime.arrayLength(remaining), 0)

        XCTAssertThrowsError(
            try instanceCall(runtime, value, "setSpan(Ljava/lang/Object;IIII)V", [span, .int32(0), .int32(22), .int32(33)])
        ) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IndexOutOfBoundsException;")
        }
    }

    func testSpannableStringCopyKeepsTextAndSpans() throws {
        let runtime = runtime()
        let source = try spannable(runtime, "hello world")
        let span = try newInstance(
            runtime, "Landroid/text/style/URLSpan;", "<init>(Ljava/lang/String;)V",
            [runtime.newString("https://example.com")]
        )
        try instanceCall(runtime, source, "setSpan(Ljava/lang/Object;IIII)V", [span, .int32(0), .int32(5), .int32(33)])
        let copy = try newInstance(
            runtime, "Landroid/text/SpannableString;", "<init>(Ljava/lang/CharSequence;)V", [source]
        )
        XCTAssertEqual(text(runtime, copy), "hello world")
        XCTAssertEqual(try instanceCall(runtime, copy, "getSpanEnd(Ljava/lang/Object;)I", [span]).asInt32, 5)
    }

    // MARK: - Linkify

    func testLinkifyMasksAndUrlEmailSpans() throws {
        let runtime = runtime()
        let cls = try runtime.linkClass("Landroid/text/util/Linkify;")
        try runtime.ensureInitialized(cls)
        let masks = Dictionary(uniqueKeysWithValues: cls.staticFields.enumerated().map { ($0.element.name, cls.staticValues[$0.offset].asInt32) })
        XCTAssertEqual(masks["WEB_URLS"], 1)
        XCTAssertEqual(masks["EMAIL_ADDRESSES"], 2)
        XCTAssertEqual(masks["PHONE_NUMBERS"], 4)
        XCTAssertEqual(masks["MAP_ADDRESSES"], 8)
        XCTAssertEqual(masks["ALL"], 15)

        let source = "see https://example.com/a. write me@example.com"
        let value = try spannable(runtime, source)
        let added = try staticCall(
            runtime, "Landroid/text/util/Linkify;", "addLinks", "(Landroid/text/Spannable;I)Z",
            [value, .int32(15)]
        )
        XCTAssertTrue(added.asBoolean)

        let spans = try instanceCall(
            runtime, value, "getSpans(IILjava/lang/Class;)[Ljava/lang/Object;",
            [.int32(0), .int32(Int32(source.utf16.count)), try classValue(runtime, "Landroid/text/style/URLSpan;")]
        )
        XCTAssertEqual(runtime.arrayLength(spans), 2)
        let first = runtime.arrayElement(spans, 0)
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, first, "getURL()Ljava/lang/String;")),
            "https://example.com/a"
        )
        let second = runtime.arrayElement(spans, 1)
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, second, "getURL()Ljava/lang/String;")),
            "mailto:me@example.com"
        )
        XCTAssertEqual(try instanceCall(runtime, value, "getSpanFlags(Ljava/lang/Object;)I", [first]).asInt32, 33)
    }

    func testLinkifyMaskSkipsOtherKindsAndReportsNoLinks() throws {
        let runtime = runtime()
        let urlsOnly = try spannable(runtime, "https://example.com/a")
        let emailAdded = try staticCall(
            runtime, "Landroid/text/util/Linkify;", "addLinks", "(Landroid/text/Spannable;I)Z",
            [urlsOnly, .int32(2)]
        )
        XCTAssertFalse(emailAdded.asBoolean)

        let plain = try spannable(runtime, "nothing to see here")
        let added = try staticCall(
            runtime, "Landroid/text/util/Linkify;", "addLinks", "(Landroid/text/Spannable;I)Z",
            [plain, .int32(15)]
        )
        XCTAssertFalse(added.asBoolean)
    }

    // MARK: - Inert method singletons

    func testPasswordTransformationIsASharedInertInstance() throws {
        let runtime = runtime()
        let first = try staticCall(
            runtime, "Landroid/text/method/PasswordTransformationMethod;", "getInstance",
            "()Landroid/text/method/PasswordTransformationMethod;"
        )
        let second = try staticCall(
            runtime, "Landroid/text/method/PasswordTransformationMethod;", "getInstance",
            "()Landroid/text/method/PasswordTransformationMethod;"
        )
        XCTAssertNotNil(first.object)
        XCTAssertEqual(first.bits, second.bits, "getInstance is a singleton")
        XCTAssertEqual(runtime.classOf(first)?.descriptor, "Landroid/text/method/PasswordTransformationMethod;")

        let source = runtime.newString("hunter2")
        let transformed = try instanceCall(
            runtime, first, "getTransformation(Ljava/lang/CharSequence;Landroid/view/View;)Ljava/lang/CharSequence;",
            [source, .null]
        )
        XCTAssertEqual(runtime.stringValue(transformed), "hunter2", "the transformation is inert")
    }

    func testLinkMovementMethodIsASharedInertInstance() throws {
        let runtime = runtime()
        let first = try staticCall(
            runtime, "Landroid/text/method/LinkMovementMethod;", "getInstance",
            "()Landroid/text/method/MovementMethod;"
        )
        let second = try staticCall(
            runtime, "Landroid/text/method/LinkMovementMethod;", "getInstance",
            "()Landroid/text/method/MovementMethod;"
        )
        XCTAssertNotNil(first.object)
        XCTAssertEqual(first.bits, second.bits, "getInstance is a singleton")
        XCTAssertTrue(
            runtime.isInstance(first, of: try runtime.linkClass("Landroid/text/method/MovementMethod;")),
            "the instance satisfies the MovementMethod parameter"
        )
    }

    // MARK: - InetAddress

    func testInetAddressResolvesLiteralsWithoutLookup() throws {
        let runtime = runtime()
        let address = try staticCall(
            runtime, "Ljava/net/InetAddress;", "getByName", "(Ljava/lang/String;)Ljava/net/InetAddress;",
            [runtime.newString("127.0.0.1")]
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, address, "getHostAddress()Ljava/lang/String;")),
            "127.0.0.1"
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, address, "getHostName()Ljava/lang/String;")),
            "127.0.0.1"
        )
        XCTAssertEqual(runtime.stringValue(try instanceCall(runtime, address, "toString()Ljava/lang/String;")), "/127.0.0.1")
        XCTAssertEqual(try instanceCall(runtime, address, "hashCode()I").asInt32, 2130706433)

        let same = try staticCall(
            runtime, "Ljava/net/InetAddress;", "getByName", "(Ljava/lang/String;)Ljava/net/InetAddress;",
            [runtime.newString("127.0.0.1")]
        )
        XCTAssertTrue(try instanceCall(runtime, address, "equals(Ljava/lang/Object;)Z", [same]).asBoolean)
        XCTAssertFalse(try instanceCall(runtime, address, "equals(Ljava/lang/Object;)Z", [runtime.newString("x")]).asBoolean)

        let v6 = try staticCall(
            runtime, "Ljava/net/InetAddress;", "getByName", "(Ljava/lang/String;)Ljava/net/InetAddress;",
            [runtime.newString("::1")]
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, v6, "getHostAddress()Ljava/lang/String;")),
            "0:0:0:0:0:0:0:1"
        )
    }

    func testInetAddressFailsUnknownNamesLikeTheJDK() throws {
        let runtime = runtime()
        XCTAssertThrowsError(
            try staticCall(
                runtime, "Ljava/net/InetAddress;", "getByName", "(Ljava/lang/String;)Ljava/net/InetAddress;",
                [runtime.newString("mihoncompat.invalid")]
            )
        ) { error in
            let exception = error as? VMJavaException
            XCTAssertEqual(exception?.classDescriptor, "Ljava/net/UnknownHostException;")
            XCTAssertEqual(exception?.message, "mihoncompat.invalid")
        }
        XCTAssertThrowsError(
            try staticCall(
                runtime, "Ljava/net/InetAddress;", "getAllByName", "(Ljava/lang/String;)[Ljava/net/InetAddress;",
                [runtime.newString("mihoncompat.invalid")]
            )
        ) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/net/UnknownHostException;")
        }
    }

    func testInetAddressLocalNamesAndLocalHost() throws {
        let runtime = runtime()
        let all = try staticCall(
            runtime, "Ljava/net/InetAddress;", "getAllByName", "(Ljava/lang/String;)[Ljava/net/InetAddress;",
            [runtime.newString("localhost")]
        )
        XCTAssertGreaterThanOrEqual(runtime.arrayLength(all), 1)
        let first = runtime.arrayElement(all, 0)
        XCTAssertFalse(
            (runtime.stringValue(try instanceCall(runtime, first, "getHostAddress()Ljava/lang/String;")) ?? "").isEmpty
        )

        let local = try staticCall(runtime, "Ljava/net/InetAddress;", "getLocalHost", "()Ljava/net/InetAddress;")
        XCTAssertNotNil(local.object)
        XCTAssertFalse(
            (runtime.stringValue(try instanceCall(runtime, local, "getHostAddress()Ljava/lang/String;")) ?? "").isEmpty
        )

        let loopback = try staticCall(
            runtime, "Ljava/net/InetAddress;", "getByName", "(Ljava/lang/String;)Ljava/net/InetAddress;",
            [runtime.newString("")]
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, loopback, "getHostAddress()Ljava/lang/String;")),
            "127.0.0.1"
        )
    }

    func testUnknownHostExceptionConstructorStoresMessage() throws {
        let runtime = runtime()
        let exception = try newInstance(
            runtime, "Ljava/net/UnknownHostException;", "<init>(Ljava/lang/String;)V",
            [runtime.newString("example.invalid")]
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, exception, "getMessage()Ljava/lang/String;")),
            "example.invalid"
        )
    }

    // MARK: - URI

    func testUriRelativizeFollowsJDKPrefixRules() throws {
        let runtime = runtime()
        let base = try uri(runtime, "https://example.com/a/b/")
        let child = try uri(runtime, "https://example.com/a/b/c?q=1#f")
        let relative = try instanceCall(runtime, base, "relativize(Ljava/net/URI;)Ljava/net/URI;", [child])
        XCTAssertEqual(runtime.classOf(relative)?.descriptor, "Ljava/net/URI;")
        XCTAssertEqual(text(runtime, relative), "c?q=1#f")

        let noSlash = try uri(runtime, "https://example.com/a/b")
        let sibling = try uri(runtime, "https://example.com/a/b/c")
        XCTAssertEqual(
            text(runtime, try instanceCall(runtime, noSlash, "relativize(Ljava/net/URI;)Ljava/net/URI;", [sibling])),
            "c"
        )

        let foreign = try uri(runtime, "https://other.example/x")
        XCTAssertEqual(
            text(runtime, try instanceCall(runtime, base, "relativize(Ljava/net/URI;)Ljava/net/URI;", [foreign])),
            "https://other.example/x"
        )
        let prefixOnly = try uri(runtime, "https://example.com/a/bc/d")
        XCTAssertEqual(
            text(runtime, try instanceCall(runtime, base, "relativize(Ljava/net/URI;)Ljava/net/URI;", [prefixOnly])),
            "https://example.com/a/bc/d"
        )

        let same = try uri(runtime, "https://example.com/a/b/")
        XCTAssertEqual(text(runtime, try instanceCall(runtime, base, "relativize(Ljava/net/URI;)Ljava/net/URI;", [same])), "")
    }

    func testUriToASCIIStringPercentEncodesNonASCII() throws {
        let runtime = runtime()
        let value = try uri(runtime, "https://example.com/a b/\u{00FC}")
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, value, "toASCIIString()Ljava/lang/String;")),
            "https://example.com/a%20b/%C3%BC"
        )
        let plain = try uri(runtime, "https://example.com/a%20b")
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, plain, "toASCIIString()Ljava/lang/String;")),
            "https://example.com/a%20b"
        )
    }
}
