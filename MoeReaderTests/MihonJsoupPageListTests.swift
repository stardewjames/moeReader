import Foundation
import XCTest
@testable import MoeReader

/// Chapter-to-page parsers select reader containers, read lazy-image attributes
/// and filter image URLs by a path fragment. These cases pin the engine
/// behavior those parsers depend on, including documents whose image URLs are
/// not image elements at all.
final class MihonJsoupPageListTests: XCTestCase {
    private func staticMethod(
        _ runtime: VMRuntime,
        _ owner: String,
        _ name: String,
        _ signature: String
    ) throws -> VMMethod {
        let cls = try runtime.linkClass(owner)
        return try XCTUnwrap(cls.lookupStatic(name, signature), "missing \(owner).\(name)\(signature)")
    }

    private func member(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key), "missing \(key)")
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func parseDocument(
        _ runtime: VMRuntime,
        _ html: String,
        baseUri: String = "https://example.test/page"
    ) throws -> VMValue {
        let parse = try staticMethod(
            runtime, "Lorg/jsoup/Jsoup;", "parse",
            "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;"
        )
        return try runtime.invoke(parse, [runtime.newString(html), runtime.newString(baseUri)])
    }

    /// The stream overload a parser uses when it hands `ResponseBody.byteStream()`
    /// straight to jsoup: the engine has to read the payload, not an empty stream.
    private func parseStream(
        _ runtime: VMRuntime,
        _ html: String,
        charset: String?,
        baseUri: String
    ) throws -> VMValue {
        let stream = runtime.makeNative(
            "Ljava/io/ByteArrayInputStream;",
            payload: Data(html.utf8)
        )
        let parse = try staticMethod(
            runtime, "Lorg/jsoup/Jsoup;", "parse",
            "(Ljava/io/InputStream;Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;"
        )
        return try runtime.invoke(parse, [
            stream,
            charset.map { runtime.newString($0) } ?? .null,
            runtime.newString(baseUri),
        ])
    }

    private func select(_ runtime: VMRuntime, in root: VMValue, _ selector: String) throws -> VMValue {
        try member(runtime, root, "select(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString(selector)])
    }

    private func selectFirst(_ runtime: VMRuntime, in root: VMValue, _ selector: String) throws -> VMValue {
        try member(runtime, root, "selectFirst(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [runtime.newString(selector)])
    }

    private func size(_ runtime: VMRuntime, of elements: VMValue) throws -> Int {
        Int(try member(runtime, elements, "size()I").asInt32)
    }

    private func attribute(_ runtime: VMRuntime, of element: VMValue, _ name: String) throws -> String? {
        runtime.stringValue(try member(
            runtime,
            element,
            "attr(Ljava/lang/String;)Ljava/lang/String;",
            [runtime.newString(name)]
        ))
    }

    private func hasAttribute(_ runtime: VMRuntime, _ element: VMValue, _ name: String) throws -> Bool {
        try member(runtime, element, "hasAttr(Ljava/lang/String;)Z", [runtime.newString(name)]).asBoolean
    }

    /// Reader markup with three container shapes a lazy-loading chapter uses:
    /// page-break wrappers, gallery list items and text blocks that must not
    /// double-count a gallery they contain.
    func testReaderContainersExcludeNestedGalleries() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <div class="reading-content">\
        <div class="text-left">\
        <p><img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-src="/wp-content/uploads/01.jpg"></p>\
        <p><img data-src="/wp-content/uploads/02.jpg"></p>\
        </div>\
        <li class="blocks-gallery-item"><figure><img src="/wp-content/uploads/03.jpg"></figure></li>\
        <div class="page-break"><img data-lazy-src="/wp-content/uploads/04.jpg"></div>\
        <div class="text-left"><div class="blocks-gallery-item"><img src="/wp-content/uploads/gallery.jpg"></div></div>\
        </div>
        """, baseUri: "https://example.test/komik/slug/chapter-1/")

        let sections = try select(
            runtime,
            in: document,
            "div.page-break, li.blocks-gallery-item, .reading-content .text-left:not(:has(.blocks-gallery-item))"
        )
        XCTAssertEqual(try size(runtime, of: sections), 3, "the text block wrapping a gallery is not a section")
        let nodes = try XCTUnwrap(runtime.listItems(sections))

        let lazy = try selectFirst(runtime, in: nodes[0], "img")
        XCTAssertNotEqual(lazy.bits, 0, "first section has an image")
        XCTAssertTrue(try hasAttribute(runtime, lazy, "data-src"))
        XCTAssertEqual(try attribute(runtime, of: lazy, "abs:data-src"), "https://example.test/wp-content/uploads/01.jpg")

        let galleryImage = try XCTUnwrap(runtime.listItems(try select(runtime, in: nodes[1], "img"))?.first)
        XCTAssertEqual(try attribute(runtime, of: galleryImage, "abs:src"), "https://example.test/wp-content/uploads/03.jpg")

        let pageBreakImage = try XCTUnwrap(runtime.listItems(try select(runtime, in: nodes[2], "img"))?.first)
        XCTAssertEqual(try attribute(runtime, of: pageBreakImage, "abs:data-lazy-src"), "https://example.test/wp-content/uploads/04.jpg")
        // A missing lazy attribute resolves to the empty string, like jsoup.
        XCTAssertEqual(try attribute(runtime, of: pageBreakImage, "abs:data-src"), "")
    }

    /// A page parser can select the image elements themselves and then ask each
    /// one for its inner `img`. jsoup's `Element.selectFirst` starts at the
    /// receiver, so the image answers with itself; otherwise every entry in the
    /// list is dropped and the chapter looks empty.
    func testElementSelectFirstIncludesReceiver() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <div class="reading-content">\
        <img class="chapter-image" src="  \n\t https://cdn.test/manga/1.jpg">\
        <img class="chapter-image" src="https://cdn.test/manga/2.jpg">\
        <div class="reading-footer"><span>credit</span></div>\
        </div>
        """, baseUri: "https://example.test/chapter/1/")

        let images = try select(runtime, in: document, "div.reading-content img")
        XCTAssertEqual(try size(runtime, of: images), 2)
        let nodes = try XCTUnwrap(runtime.listItems(images))
        for (index, image) in nodes.enumerated() {
            let inner = try selectFirst(runtime, in: image, "img")
            XCTAssertNotEqual(inner.bits, 0, "image \(index) matches `img` itself")
            XCTAssertEqual(
                try attribute(runtime, of: inner, "abs:src"),
                "https://cdn.test/manga/\(index + 1).jpg"
            )
        }

        // A non-image receiver still finds its descendants.
        let footer = try XCTUnwrap(runtime.listItems(try select(runtime, in: document, "div.reading-footer"))?.first)
        XCTAssertEqual(try size(runtime, of: try select(runtime, in: footer, "span")), 1)
        let documentImages = try select(runtime, in: document, "div.reading-content img")
        XCTAssertEqual(try size(runtime, of: documentImages), 2)
    }

    /// jsoup's `getElements*` helpers collect from the receiver too, so an
    /// element lookup on a node starts with that node.
    func testElementLookupHelpersIncludeReceiver() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <div id="x" class="c" data-k="v"><span id="s" class="c">hello</span></div>
        """, baseUri: "https://example.test/")
        let x = try XCTUnwrap(runtime.listItems(try select(runtime, in: document, "#x"))?.first)

        XCTAssertEqual(try size(runtime, of: try member(runtime, x, "getAllElements()Lorg/jsoup/select/Elements;")), 2)
        XCTAssertEqual(try size(runtime, of: try member(runtime, x, "getElementsByTag(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString("div")])), 1)
        XCTAssertEqual(try size(runtime, of: try member(runtime, x, "getElementsByClass(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString("c")])), 2)

        let selfById = try member(runtime, x, "getElementById(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [runtime.newString("x")])
        XCTAssertNotEqual(selfById.bits, 0)
        XCTAssertEqual(runtime.stringValue(try member(runtime, selfById, "tagName()Ljava/lang/String;")), "div")

        XCTAssertEqual(
            try size(runtime, of: try member(runtime, x, "getElementsContainingText(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString("hello")])),
            2
        )
        XCTAssertEqual(
            try size(runtime, of: try member(runtime, x, "getElementsByAttribute(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString("data-k")])),
            1
        )
        XCTAssertEqual(
            try size(runtime, of: try member(
                runtime, x, "getElementsByAttributeValue(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/select/Elements;",
                [runtime.newString("data-k"), runtime.newString("v")]
            )),
            1
        )
        // `Not` keeps elements without the attribute; only the receiver has it.
        XCTAssertEqual(
            try size(runtime, of: try member(
                runtime, x, "getElementsByAttributeValueNot(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/select/Elements;",
                [runtime.newString("data-k"), runtime.newString("other")]
            )),
            2
        )
    }

    /// `Elements.select` applies the query at each root and includes a root
    /// that matches, without repeating a match shared by overlapping roots.
    func testElementsSelectIncludesRootsWithoutDuplicates() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <div id="outer"><div id="inner"><p>text</p></div></div>
        """, baseUri: "https://example.test/")

        let divs = try select(runtime, in: document, "div")
        XCTAssertEqual(try size(runtime, of: divs), 2)
        let nested = try member(runtime, divs, "select(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString("div")])
        XCTAssertEqual(try size(runtime, of: nested), 2)
        let ids = try XCTUnwrap(runtime.listItems(nested)).map { try attribute(runtime, of: $0, "id") }
        XCTAssertEqual(ids, ["outer", "inner"])

        let all = try member(runtime, divs, "select(Ljava/lang/String;)Lorg/jsoup/select/Elements;", [runtime.newString("*")])
        XCTAssertEqual(try size(runtime, of: all), 3)
    }

    /// Chapter images sometimes sit behind a proxy URL, so the parser matches
    /// the path fragment in both its raw and percent-escaped spellings and
    /// ignores cover art and srcset-only images.
    func testPathFragmentSelectorMatchesRawAndEscapedImageSources() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <img src="/serie/slug/01.jpg">\
        <img src="https://proxy.test/?url=https%3A%2F%2Fcdn.test%2Fserie%2Fslug%2F02.jpg&amp;w=800">\
        <img src="/covers/cover.png">\
        <img srcset="/serie/slug/03.jpg 1x">
        """, baseUri: "https://example.test/ver/slug/capitulo-1")

        let pages = try select(runtime, in: document, "img[src*=/serie/], img[src*=%2Fserie%2F]")
        XCTAssertEqual(try size(runtime, of: pages), 2)
        let nodes = try XCTUnwrap(runtime.listItems(pages))
        XCTAssertEqual(try attribute(runtime, of: nodes[0], "abs:src"), "https://example.test/serie/slug/01.jpg")
        // The entity in the HTML attribute decodes once; the escaped path stays.
        XCTAssertEqual(
            try attribute(runtime, of: nodes[1], "src"),
            "https://proxy.test/?url=https%3A%2F%2Fcdn.test%2Fserie%2Fslug%2F02.jpg&w=800"
        )
        XCTAssertEqual(try size(runtime, of: try select(runtime, in: document, "img")), 4)
    }

    /// A client-rendered reader can publish its image list as a JSON string
    /// inside a script. That string is text, not markup: no image element
    /// exists, which is a document-side absence rather than a selector miss.
    func testScriptEmbeddedImageListYieldsNoImageElements() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <div id="reader"></div>\
        <script>window.__readerData.push([1,"[\\"https://cdn.test/serie/slug/01.jpg\\",\\"https://cdn.test/serie/slug/02.jpg\\"]"])</script>
        """, baseUri: "https://example.test/ver/slug/capitulo-1")

        XCTAssertEqual(try size(runtime, of: try select(runtime, in: document, "img")), 0)
        XCTAssertEqual(try size(runtime, of: try select(runtime, in: document, "img[src*=/serie/], img[src*=%2Fserie%2F]")), 0)

        let scripts = try select(runtime, in: document, "script")
        XCTAssertEqual(try size(runtime, of: scripts), 1)
        let script = try XCTUnwrap(runtime.listItems(scripts)?.first)
        let data = try XCTUnwrap(runtime.stringValue(try member(runtime, script, "data()Ljava/lang/String;")))
        XCTAssertTrue(data.contains("https://cdn.test/serie/slug/01.jpg"))
        XCTAssertEqual(try size(runtime, of: try select(runtime, in: script, "img")), 0)
    }

    /// A fragment-only link resolves against the document base URI exactly as
    /// java.net.URL does, so `abs:href` is the listing URL with a trailing `#`
    /// rather than an empty string.
    func testFragmentHrefResolvesToDocumentBase() throws {
        let runtime = VMRuntime()
        let base = "https://example.test/komik/slug/ajax/chapters/"
        let document = try parseDocument(runtime, """
        <ul><li><a href="#">Chapter 124</a></li><li><a href="chapter-121/">Chapter 121</a></li></ul>
        """, baseUri: base)

        let links = try XCTUnwrap(runtime.listItems(try select(runtime, in: document, "a")))
        XCTAssertEqual(try attribute(runtime, of: links[0], "abs:href"), base + "#")
        XCTAssertEqual(try attribute(runtime, of: links[1], "abs:href"), base + "chapter-121/")
        // A parser that turns the path into a chapter slug therefore sees the
        // listing page's own name for a placeholder link.
        let resolved = try XCTUnwrap(URL(string: try XCTUnwrap(try attribute(runtime, of: links[0], "abs:href"))))
        XCTAssertEqual(resolved.lastPathComponent, "chapters")
    }

    /// An unrelated page (directory listing, parking page) has none of the
    /// detail markup: `selectFirst` answers null and collection helpers answer
    /// empty, which is the same result jsoup gives.
    func testMissingDetailMarkupReturnsNullAndEmptyCollections() throws {
        let runtime = VMRuntime()
        let document = try parseDocument(runtime, """
        <html><body><div class="content"><h1>Index of /</h1>\
        <table><thead><tr><th><a href="?ND">Name</a></th></tr></thead>\
        <tbody><tr><td><a href="/wp-content/"><img class="icon" src="/assets/folder.svg" alt="Directory">wp-content</a></td></tr></tbody>\
        </table></div></body></html>
        """, baseUri: "https://example.test")

        let title = try selectFirst(runtime, in: document, "div.post-title h3, div.post-title h1, #manga-title > h1")
        XCTAssertEqual(title.bits, 0)

        let summary = try select(runtime, in: document, "div.summary-content, div.summary-heading:contains(Status) + div")
        XCTAssertEqual(try size(runtime, of: summary), 0)
        let texts = try member(runtime, summary, "eachText()Ljava/util/List;")
        XCTAssertEqual(runtime.listItems(texts)?.count, 0)
        XCTAssertEqual(try size(runtime, of: try select(runtime, in: document, "a[data-post]")), 0)
        XCTAssertEqual(try size(runtime, of: try select(runtime, in: document, "input.rating-post-id")), 0)
    }

    /// The page-list entry point can parse the response stream directly; the
    /// document then has the requested base URI and the full body.
    func testStreamParsePreservesBodyAndBaseUri() throws {
        let runtime = VMRuntime()
        let html = """
        <div class="reader">\
        <img src="/serie/slug/01.jpg"><img src="/serie/slug/02.jpg">\
        </div>
        """
        let base = "https://example.test/ver/slug/capitulo-2"
        for charset in ["UTF-8", nil] as [String?] {
            let document = try parseStream(runtime, html, charset: charset, baseUri: base)
            let location = try member(runtime, document, "location()Ljava/lang/String;")
            XCTAssertEqual(runtime.stringValue(location), base, "charset \(charset ?? "<null>")")
            let images = try select(runtime, in: document, "img[src*=/serie/]")
            XCTAssertEqual(try size(runtime, of: images), 2)
            XCTAssertEqual(
                try attribute(runtime, of: try XCTUnwrap(runtime.listItems(images)?.first), "abs:src"),
                "https://example.test/serie/slug/01.jpg"
            )
        }
    }
}
