import XCTest
@testable import MoeReader

/// jsoup's `Elements` is a `java.util.List`, so Kotlin resolves `List`-typed
/// stdlib overloads for it. Those overloads read through the collection
/// payload, which the jsoup node list must provide: a page-list parser that
/// selects images, drops the trailing element and reads `abs:` attributes
/// otherwise sees an empty list and returns no pages.
final class MihonJsoupParseGapTests: XCTestCase {
    private func parseDocument(
        _ runtime: VMRuntime,
        _ html: String,
        baseUri: String = "https://example.test/page"
    ) throws -> VMValue {
        let cls = try runtime.linkClass("Lorg/jsoup/Jsoup;")
        let parse = try XCTUnwrap(
            cls.lookupStatic("parse", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;")
        )
        return try runtime.invoke(parse, [runtime.newString(html), runtime.newString(baseUri)])
    }

    private func select(_ runtime: VMRuntime, in root: VMValue, _ selector: String) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(root))
        let method = try XCTUnwrap(cls.lookupVirtual(key: "select(Ljava/lang/String;)Lorg/jsoup/select/Elements;"))
        return try runtime.invoke(method, [root, runtime.newString(selector)])
    }

    private func staticCall(
        _ runtime: VMRuntime,
        _ owner: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(owner)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try runtime.invoke(method, arguments)
    }

    private func member(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key))
        return try runtime.invoke(method, [receiver] + arguments)
    }

    /// `Element.attr("abs:<attribute>")`: how a page parser turns a possibly
    /// relative attribute into a page URL.
    private func absolute(
        _ runtime: VMRuntime,
        of element: VMValue,
        attribute: String
    ) throws -> String? {
        let value = try member(
            runtime,
            element,
            "attr(Ljava/lang/String;)Ljava/lang/String;",
            [runtime.newString("abs:" + attribute)]
        )
        return runtime.stringValue(value)
    }

    /// The page-list shape that regressed: `Elements.select` result ->
    /// `dropLast(List, 1)` -> `attr("abs:src")` per element.
    func testElementsListOverloadsSeeSelectedNodes() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(
            runtime,
            """
            <div class="separator"><a><img src="/pages/1.jpg" /></a></div>\
            <div class="separator"><a><img src="/pages/2.jpg" /></a></div>\
            <div class="separator"><a><img src="/pages/3.jpg" /></a></div>\
            <div class="separator"><a><img src="/pages/credit.png" /></a></div>
            """,
            baseUri: "https://example.test/chapter/1"
        )
        let images = try select(runtime, in: document, ".separator img")
        XCTAssertEqual(try member(runtime, images, "size()I").asInt32, 4)
        XCTAssertEqual(runtime.listItems(images)?.count, 4)
        // The node list view is cached, so repeated helper calls stay linear.
        XCTAssertTrue(runtime.listPayload(images) === runtime.listPayload(images))

        // `List` overloads, the ones Kotlin emits when the receiver is an
        // `Elements`; the `Iterable` overload always worked.
        let pages = try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "dropLast",
            "(Ljava/util/List;I)Ljava/util/List;",
            [images, .int32(1)]
        )
        let pageElements = try XCTUnwrap(runtime.listItems(pages))
        XCTAssertEqual(pageElements.count, 3)
        XCTAssertEqual(try absolute(runtime, of: pageElements[0], attribute: "src"), "https://example.test/pages/1.jpg")
        XCTAssertEqual(try absolute(runtime, of: pageElements[2], attribute: "src"), "https://example.test/pages/3.jpg")

        let tail = try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "takeLast",
            "(Ljava/util/List;I)Ljava/util/List;",
            [images, .int32(1)]
        )
        let tailElements = try XCTUnwrap(runtime.listItems(tail))
        XCTAssertEqual(tailElements.count, 1)
        XCTAssertEqual(try absolute(runtime, of: tailElements[0], attribute: "src"), "https://example.test/pages/credit.png")

        let lastIndex = try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "getLastIndex",
            "(Ljava/util/List;)I",
            [images]
        )
        XCTAssertEqual(lastIndex.asInt32, 3)

        // A page parser that keeps the last element (`last(List)`) and reads
        // its `abs:` attribute must see the node, not an empty list.
        let lastImage = try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "last",
            "(Ljava/util/List;)Ljava/lang/Object;",
            [images]
        )
        XCTAssertEqual(try absolute(runtime, of: lastImage, attribute: "src"), "https://example.test/pages/credit.png")

        // Iterating the same `Elements` still walks the nodes in order.
        let iterator = try member(runtime, images, "iterator()Ljava/util/Iterator;")
        var iterated: [String] = []
        while try member(runtime, iterator, "hasNext()Z").asBoolean {
            let next = try member(runtime, iterator, "next()Ljava/lang/Object;")
            iterated.append(try absolute(runtime, of: next, attribute: "src") ?? "")
        }
        XCTAssertEqual(iterated, [
            "https://example.test/pages/1.jpg",
            "https://example.test/pages/2.jpg",
            "https://example.test/pages/3.jpg",
            "https://example.test/pages/credit.png",
        ])
    }

    /// Lazy-loaded pages: the selector matches `data-src` only (attributes on
    /// separate lines, as served), and `abs:` resolves against the document
    /// base URI, including protocol-relative URLs.
    func testDataSrcAttributesResolveAgainstBaseUri() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(
            runtime,
            """
            <div class="pages">
              <img
                 data-src="//cdn.example.test/pages/1.jpg"
                 src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" />
              <img data-src="/pages/2.jpg" />
              <img src="/pages/placeholder.png" />
            </div>
            """,
            baseUri: "https://example.test/chapter/2"
        )
        let lazy = try select(runtime, in: document, "img[data-src]")
        XCTAssertEqual(try member(runtime, lazy, "size()I").asInt32, 2)

        let first = try member(runtime, lazy, "first()Lorg/jsoup/nodes/Element;")
        XCTAssertNotNil(runtime.payload(first, as: JElementPayload.self))
        XCTAssertEqual(try absolute(runtime, of: first, attribute: "data-src"), "https://cdn.example.test/pages/1.jpg")
        let second = try member(runtime, lazy, "get(I)Lorg/jsoup/nodes/Element;", [.int32(1)])
        XCTAssertEqual(try absolute(runtime, of: second, attribute: "data-src"), "https://example.test/pages/2.jpg")

        // `Elements.attr` returns the first node's value, resolved.
        let batch = try member(
            runtime,
            lazy,
            "attr(Ljava/lang/String;)Ljava/lang/String;",
            [runtime.newString("abs:data-src")]
        )
        XCTAssertEqual(runtime.stringValue(batch), "https://cdn.example.test/pages/1.jpg")

        // The same set through a `List` helper stays addressable.
        let dropped = try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "dropLast",
            "(Ljava/util/List;I)Ljava/util/List;",
            [lazy, .int32(1)]
        )
        let remaining = try XCTUnwrap(runtime.listItems(dropped))
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(try absolute(runtime, of: remaining[0], attribute: "data-src"), "https://cdn.example.test/pages/1.jpg")
    }
}
