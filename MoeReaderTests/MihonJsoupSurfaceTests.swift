import XCTest
@testable import MoeReader

/// Native jsoup surface added for the whole-index gap list: parser factories,
/// typed evaluators, tree accessors, attributes and the helper statics.
final class MihonJsoupSurfaceTests: XCTestCase {
    private func virtual(_ runtime: VMRuntime, _ owner: String, _ name: String, _ signature: String) throws -> VMMethod {
        let cls = try runtime.linkClass(owner)
        return try XCTUnwrap(cls.lookupVirtual(key: name + signature), "missing \(owner).\(name)\(signature)")
    }

    private func static_(_ runtime: VMRuntime, _ owner: String, _ name: String, _ signature: String) throws -> VMMethod {
        let cls = try runtime.linkClass(owner)
        return try XCTUnwrap(cls.lookupStatic(name, signature), "missing \(owner).\(name)\(signature)")
    }

    private func native(_ runtime: VMRuntime, _ owner: String, _ name: String, _ signature: String, _ args: [VMValue], receiver: VMValue? = nil) throws -> VMValue {
        let method = try virtual(runtime, owner, name, signature)
        return try runtime.invoke(method, [receiver ?? .null] + args)
    }

    private func parseDocument(_ runtime: VMRuntime, _ html: String, baseUri: String = "https://example.test/page") throws -> VMValue {
        let parse = try static_(runtime, "Lorg/jsoup/Jsoup;", "parse", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;")
        return try runtime.invoke(parse, [runtime.newString(html), runtime.newString(baseUri)])
    }

    private func elements(_ runtime: VMRuntime, in root: VMValue, selector: String) throws -> VMValue {
        try native(runtime, "Lorg/jsoup/nodes/Element;", "select", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString(selector)], receiver: root)
    }

    private func first(_ runtime: VMRuntime, of elements: VMValue) throws -> VMValue {
        try native(runtime, "Lorg/jsoup/select/Elements;", "first", "()Lorg/jsoup/nodes/Element;", [], receiver: elements)
    }

    private func string(_ runtime: VMRuntime, _ owner: String, _ name: String, _ signature: String, _ args: [VMValue] = [], receiver: VMValue? = nil) throws -> String? {
        runtime.stringValue(try native(runtime, owner, name, signature, args, receiver: receiver))
    }

    private func node(_ runtime: VMRuntime, _ value: VMValue) -> JNode? {
        runtime.payload(value, as: JElementPayload.self)?.node
    }

    func testParserFactoriesChooseTreeBuilder() throws {
        let runtime = VMRuntime()
        let parseWithParser = try static_(
            runtime, "Lorg/jsoup/Jsoup;", "parse",
            "(Ljava/lang/String;Ljava/lang/String;Lorg/jsoup/parser/Parser;)Lorg/jsoup/nodes/Document;"
        )
        let htmlParser = try runtime.invoke(try static_(runtime, "Lorg/jsoup/parser/Parser;", "htmlParser", "()Lorg/jsoup/parser/Parser;"), [])
        let xmlParser = try runtime.invoke(try static_(runtime, "Lorg/jsoup/parser/Parser;", "xmlParser", "()Lorg/jsoup/parser/Parser;"), [])
        XCTAssertEqual(runtime.payload(htmlParser, as: JParserPayload.self)?.xml, false)
        XCTAssertEqual(runtime.payload(xmlParser, as: JParserPayload.self)?.xml, true)

        let markup = "<feed><entry><title>A &amp; B</title><link href=\"https://x.test/a\"/></entry></feed>"
        let xmlDocument = try runtime.invoke(parseWithParser, [runtime.newString(markup), runtime.newString("https://x.test/feed"), xmlParser])

        // XML: no implied html/head/body wrappers, self-closing element kept.
        let htmlElements = try elements(runtime, in: xmlDocument, selector: "html")
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", [], receiver: htmlElements).asInt32, 0)
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Document;", "location", "()Ljava/lang/String;", receiver: xmlDocument), "https://x.test/feed")
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Document;", "title", "()Ljava/lang/String;", receiver: xmlDocument), "A & B")

        let entry = try first(runtime, of: try elements(runtime, in: xmlDocument, selector: "entry"))
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "attr", "(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("href")], receiver: try first(runtime, of: try elements(runtime, in: entry, selector: "link"))), "https://x.test/a")

        // `Parser.htmlParser()` keeps the HTML insertion mode.
        let htmlDocument = try runtime.invoke(parseWithParser, [runtime.newString(markup), runtime.newString("https://x.test/feed"), htmlParser])
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", [], receiver: try elements(runtime, in: htmlDocument, selector: "html")).asInt32, 1)
    }

    func testElementTreeAndAttributeMembers() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <div id="main"><p class="lead">Lead <a href="/x">link</a></p><p data-x="1">Second</p><p>Third</p></div>\
        <div class="other">Other</div>
        """)
        let lead = try first(runtime, of: try elements(runtime, in: document, selector: "p.lead"))

        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "ownText", "()Ljava/lang/String;", receiver: lead), "Lead")
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "tagName", "()Ljava/lang/String;", receiver: lead), "p")
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "absUrl", "(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("href")], receiver: try first(runtime, of: try elements(runtime, in: lead, selector: "a"))), "https://example.test/x")

        // parent / children / child / sibling walk.
        let parent = try native(runtime, "Lorg/jsoup/nodes/Node;", "parent", "()Lorg/jsoup/nodes/Element;", [], receiver: lead)
        XCTAssertEqual(node(runtime, parent)?.attribute("id"), "main")
        let children = try native(runtime, "Lorg/jsoup/nodes/Element;", "children", "()Lorg/jsoup/select/Elements;", [], receiver: parent)
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", [], receiver: children).asInt32, 3)
        let second = try native(runtime, "Lorg/jsoup/nodes/Element;", "child", "(I)Lorg/jsoup/nodes/Element;", [.int32(1)], receiver: parent)
        XCTAssertEqual(node(runtime, second)?.textContent(), "Second")
        XCTAssertEqual(node(runtime, try native(runtime, "Lorg/jsoup/nodes/Element;", "nextElementSibling", "()Lorg/jsoup/nodes/Element;", [], receiver: lead))?.textContent(), "Second")
        XCTAssertEqual(node(runtime, try native(runtime, "Lorg/jsoup/nodes/Element;", "previousElementSibling", "()Lorg/jsoup/nodes/Element;", [], receiver: second))?.textContent(), "Lead link")
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", [], receiver: try native(runtime, "Lorg/jsoup/nodes/Element;", "nextElementSiblings", "()Lorg/jsoup/select/Elements;", [], receiver: lead)).asInt32, 2)
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/nodes/Element;", "siblingIndex", "()I", [], receiver: second).asInt32, 1)

        // closest climbs to the wrapping element.
        let link = try first(runtime, of: try elements(runtime, in: lead, selector: "a"))
        let container = try native(runtime, "Lorg/jsoup/nodes/Element;", "closest", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [runtime.newString("div")], receiver: link)
        XCTAssertEqual(node(runtime, container)?.attribute("id"), "main")

        // removeAttr is observable through hasAttr and attr.
        _ = try native(runtime, "Lorg/jsoup/nodes/Element;", "removeAttr", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [runtime.newString("data-x")], receiver: second)
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/nodes/Element;", "hasAttr", "(Ljava/lang/String;)Z", [runtime.newString("data-x")], receiver: second).asBoolean, false)
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "attr", "(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("data-x")], receiver: second), "")

        // data / val / text(String) / clone.
        let script = try first(runtime, of: try elements(runtime, in: try parseDocument(runtime, "<script>var a=1;</script><input value=v><textarea>body</textarea>"), selector: "script"))
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "data", "()Ljava/lang/String;", receiver: script), "var a=1;")
        let input = try first(runtime, of: try elements(runtime, in: try parseDocument(runtime, "<input value=v>"), selector: "input"))
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "val", "()Ljava/lang/String;", receiver: input), "v")

        let clone = try native(runtime, "Lorg/jsoup/nodes/Element;", "clone", "()Lorg/jsoup/nodes/Element;", [], receiver: lead)
        let cloneNode = try XCTUnwrap(node(runtime, clone))
        XCTAssertFalse(cloneNode === node(runtime, lead)!)
        XCTAssertNil(cloneNode.parent)
        XCTAssertEqual(cloneNode.outerHTML(), node(runtime, lead)?.outerHTML())

        // wrap / unwrap: the second paragraph becomes a child of the wrapper.
        _ = try native(runtime, "Lorg/jsoup/nodes/Element;", "wrap", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [runtime.newString("<section class=\"wrapped\"></section>")], receiver: second)
        XCTAssertEqual(node(runtime, second)?.parent?.tag, "section")
        XCTAssertEqual(node(runtime, second)?.parent?.parent?.attribute("id"), "main")
        let section = try native(runtime, "Lorg/jsoup/nodes/Element;", "parent", "()Lorg/jsoup/nodes/Element;", [], receiver: second)
        _ = try native(runtime, "Lorg/jsoup/nodes/Element;", "unwrap", "()Lorg/jsoup/nodes/Element;", [], receiver: section)
        XCTAssertEqual(node(runtime, second)?.parent?.tag, "div")
        XCTAssertNil(node(runtime, section)?.parent)

        // getElementsByAttributeValue and dataset.
        let tagged = try first(runtime, of: try native(
            runtime, "Lorg/jsoup/nodes/Element;", "getElementsByAttributeValue",
            "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/select/Elements;",
            [runtime.newString("class"), runtime.newString("lead")], receiver: parent
        ))
        XCTAssertEqual(node(runtime, tagged)?.textContent(), "Lead link")
        let dataset = try native(runtime, "Lorg/jsoup/nodes/Element;", "dataset", "()Ljava/util/Map;", [], receiver: lead)
        XCTAssertNotNil(runtime.mapPayload(dataset))
    }

    func testTextNodeAndAttributesSurface() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, "<p class=\"lead\" id=\"p1\">Hello <b>world</b></p>")
        let paragraph = try first(runtime, of: try elements(runtime, in: document, selector: "p"))

        let textNodes = try native(runtime, "Lorg/jsoup/nodes/Element;", "textNodes", "()Ljava/util/List;", [], receiver: paragraph)
        let textNode = try XCTUnwrap(runtime.listPayload(textNodes)?.items.first)
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/TextNode;", "getWholeText", "()Ljava/lang/String;", receiver: textNode), "Hello ")
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/TextNode;", "text", "()Ljava/lang/String;", receiver: textNode), "Hello ")

        let childNodes = try native(runtime, "Lorg/jsoup/nodes/Element;", "childNodes", "()Ljava/util/List;", [], receiver: paragraph)
        XCTAssertEqual(runtime.listPayload(childNodes)?.items.count, 2)

        let attributes = try native(runtime, "Lorg/jsoup/nodes/Element;", "attributes", "()Lorg/jsoup/nodes/Attributes;", [], receiver: paragraph)
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Attributes;", "get", "(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("class")], receiver: attributes), "lead")
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/nodes/Attributes;", "size", "()I", [], receiver: attributes).asInt32, 2)
        XCTAssertTrue(try string(runtime, "Lorg/jsoup/nodes/Attributes;", "html", "()Ljava/lang/String;", receiver: attributes)?.contains("class=\"lead\"") == true)

        let list = try native(runtime, "Lorg/jsoup/nodes/Attributes;", "asList", "()Ljava/util/List;", [], receiver: attributes)
        let attribute = try XCTUnwrap(runtime.listPayload(list)?.items.first)
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Attribute;", "getKey", "()Ljava/lang/String;", receiver: attribute), "class")
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Attribute;", "getValue", "()Ljava/lang/String;", receiver: attribute), "lead")
    }

    func testElementsCollectionMembers() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, "<div class=\"a\" href=\"/1\"><span>One</span></div><div class=\"b\" href=\"/2\"><span>Two</span></div><span class=\"b\">Three</span>")
        let divs = try elements(runtime, in: document, selector: "div")
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "hasClass", "(Ljava/lang/String;)Z", [runtime.newString("b")], receiver: divs).asBoolean, true)

        let notB = try native(runtime, "Lorg/jsoup/select/Elements;", "not", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString(".b")], receiver: divs)
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", [], receiver: notB).asInt32, 1)

        let firstB = try native(runtime, "Lorg/jsoup/select/Elements;", "selectFirst", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [runtime.newString("span")], receiver: divs)
        XCTAssertEqual(node(runtime, firstB)?.textContent(), "One")

        let hrefs = try native(runtime, "Lorg/jsoup/select/Elements;", "eachAttr", "(Ljava/lang/String;)Ljava/util/List;", [runtime.newString("href")], receiver: divs)
        let values = try XCTUnwrap(runtime.listPayload(hrefs)).items.compactMap { runtime.stringValue($0) }
        XCTAssertEqual(values, ["/1", "/2"])

        let removed = try native(runtime, "Lorg/jsoup/select/Elements;", "remove", "()Lorg/jsoup/select/Elements;", [], receiver: try elements(runtime, in: document, selector: "span"))
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", [], receiver: removed).asInt32, 3)
        XCTAssertEqual(try native(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", [], receiver: try elements(runtime, in: document, selector: "span")).asInt32, 0)
    }

    func testTypedEvaluatorMatchesStringSelector() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, "<div class=\"item\"><a href=\"/a\">A</a></div><div class=\"item\"><a href=\"/b\">B</a></div><div class=\"other\"><a href=\"/c\">C</a></div>")

        // Build `Evaluator.Tag("div")` and select through the typed overload.
        let evaluatorClass = try runtime.linkClass("Lorg/jsoup/select/Evaluator$Tag;")
        let evaluator = VMValue.reference(runtime.allocateObject(evaluatorClass))
        let initWithTag = try XCTUnwrap(evaluatorClass.lookupVirtual(key: "<init>(Ljava/lang/String;)V"))
        _ = try runtime.invoke(initWithTag, [evaluator, runtime.newString("div")])

        let typed = try native(runtime, "Lorg/jsoup/nodes/Element;", "select", "(Lorg/jsoup/select/Evaluator;)Lorg/jsoup/select/Elements;", [evaluator], receiver: document)
        let stringly = try elements(runtime, in: document, selector: "div")
        XCTAssertEqual(
            runtime.payload(typed, as: JElementsPayload.self)?.nodes.map { $0.outerHTML() },
            runtime.payload(stringly, as: JElementsPayload.self)?.nodes.map { $0.outerHTML() }
        )

        // QueryParser.parse evaluator feeds Collector.findFirst.
        let parsed = try runtime.invoke(
            try static_(runtime, "Lorg/jsoup/select/QueryParser;", "parse", "(Ljava/lang/String;)Lorg/jsoup/select/Evaluator;"),
            [runtime.newString("div.item > a")]
        )
        let found = try runtime.invoke(
            try static_(runtime, "Lorg/jsoup/select/Collector;", "findFirst", "(Lorg/jsoup/select/Evaluator;Lorg/jsoup/nodes/Element;)Lorg/jsoup/nodes/Element;"),
            [parsed, document]
        )
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "attr", "(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("href")], receiver: found), "/a")

        // Document.createElement and typed Document.selectFirst.
        let created = try native(runtime, "Lorg/jsoup/nodes/Document;", "createElement", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [runtime.newString("DIV")], receiver: document)
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "tagName", "()Ljava/lang/String;", receiver: created), "div")
        let documentFirst = try native(runtime, "Lorg/jsoup/nodes/Document;", "selectFirst", "(Lorg/jsoup/select/Evaluator;)Lorg/jsoup/nodes/Element;", [parsed], receiver: document)
        XCTAssertEqual(node(runtime, documentFirst)?.tag, "a")

        // setBaseUri changes abs: resolution and location().
        _ = try native(runtime, "Lorg/jsoup/nodes/Document;", "setBaseUri", "(Ljava/lang/String;)V", [runtime.newString("https://cdn.test/root/")], receiver: document)
        let anchor = try first(runtime, of: try elements(runtime, in: document, selector: "a"))
        XCTAssertEqual(try string(runtime, "Lorg/jsoup/nodes/Element;", "absUrl", "(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("href")], receiver: anchor), "https://cdn.test/a")
    }

    func testHelperStaticsFailClosed() throws {
        let runtime = VMRuntime()
        let unescape = try static_(runtime, "Lorg/jsoup/nodes/Entities;", "unescape", "(Ljava/lang/String;)Ljava/lang/String;")
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(unescape, [runtime.newString("a &amp; b &#65;")])), "a & b A")

        let notEmpty = try static_(runtime, "Lorg/jsoup/helper/Validate;", "notEmpty", "(Ljava/lang/String;)V")
        XCTAssertThrowsError(try runtime.invoke(notEmpty, [runtime.newString("")]))
        XCTAssertNoThrow(try runtime.invoke(notEmpty, [runtime.newString("x")]))

        let notNull = try static_(runtime, "Lorg/jsoup/helper/Validate;", "notNull", "(Ljava/lang/Object;)V")
        XCTAssertThrowsError(try runtime.invoke(notNull, [.null]))
    }

    /// The memoised selector evaluation must stay linear-ish on a large page:
    /// the 2 MB/12k-node shape used to take minutes before per-select caching.
    func testTwoMegabytePageSelectStaysInTensOfMilliseconds() {
        var html = ""
        html.reserveCapacity(2_100_000)
        html += "<html><body><div id=\"manga-info-stats\">"
        let padding = String(repeating: "x", count: 120)
        while html.utf8.count < 2_000_000 {
            html += "<div class=\"row\"><li>Author</li><li class=\"name\">Momo</li><span>\(padding)</span></div>"
        }
        html += "</div></body></html>"

        let document = JsoupHTML.parse(html, baseUri: "https://example.test")
        XCTAssertGreaterThan(document.root.descendants().count, 8_000)

        let start = Date()
        let outer = JsoupSelector.select(document.root, selector: "div:has(> li:eq(0):contains(Author))")
        let inner = JsoupSelector.select(document.root, selector: "div#manga-info-stats > div:has(> li:eq(0):contains(Author)) > li:eq(1)")
        let elapsed = Date().timeIntervalSince(start)
        print("jsoup 2MB page: \(document.root.descendants().count) nodes, two selects in \(Int(elapsed * 1000)) ms")

        let rows = html.components(separatedBy: "class=\"row\"").count - 1
        XCTAssertEqual(outer.count, rows)
        XCTAssertFalse(inner.isEmpty)
        XCTAssertLessThan(elapsed, 5.0, "selector evaluation regressed to \(elapsed)s")
    }
}
