import XCTest
@testable import MoeReader

/// Contract of the `getMangaUpdate` path extensions take when they override
/// `HttpSource.getMangaUpdate` instead of the default implementation.
///
/// The override parses the details page itself, so two stdlib surfaces sit on
/// that path without any `HttpSource` helper in between:
///
/// - it collects the elements of every detail row (genres, author, status, ...)
///   into a set with `CollectionsKt.addAll`, then walks the shared parent to
///   read the row labels;
/// - it reads chapter ids from `input[name="chapter_ids[]"]`, a quoted
///   attribute value that itself contains brackets.
///
/// Both failed in ways that surfaced as `NullPointerException` inside the
/// extension: the set stayed empty (`get(genre)` returned null), and the
/// bracket inside the quoted value closed the attribute selector early.
final class MihonMangaUpdatePathTests: XCTestCase {
    private func virtual(_ runtime: VMRuntime, _ owner: String, _ name: String, _ signature: String) throws -> VMMethod {
        let cls = try runtime.linkClass(owner)
        return try XCTUnwrap(cls.lookupVirtual(key: name + signature), "missing \(owner).\(name)\(signature)")
    }

    private func static_(_ runtime: VMRuntime, _ owner: String, _ name: String, _ signature: String) throws -> VMMethod {
        let cls = try runtime.linkClass(owner)
        return try XCTUnwrap(cls.lookupStatic(name, signature), "missing \(owner).\(name)\(signature)")
    }

    private func call(
        _ runtime: VMRuntime,
        _ owner: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue] = [],
        receiver: VMValue? = nil
    ) throws -> VMValue {
        let method = try virtual(runtime, owner, name, signature)
        return try runtime.invoke(method, [receiver ?? .null] + arguments)
    }

    private func parse(_ runtime: VMRuntime, _ html: String) throws -> VMValue {
        try runtime.invoke(
            try static_(runtime, "Lorg/jsoup/Jsoup;", "parse", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;"),
            [runtime.newString(html), runtime.newString("https://example.test/books/1")]
        )
    }

    private func select(_ runtime: VMRuntime, _ root: VMValue, _ selector: String) throws -> VMValue {
        try call(
            runtime, "Lorg/jsoup/nodes/Element;", "select", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;",
            [runtime.newString(selector)], receiver: root
        )
    }

    private func selectFirst(_ runtime: VMRuntime, _ root: VMValue, _ selector: String) throws -> VMValue {
        try call(
            runtime, "Lorg/jsoup/nodes/Element;", "selectFirst", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;",
            [runtime.newString(selector)], receiver: root
        )
    }

    private func size(_ runtime: VMRuntime, _ elements: VMValue) throws -> Int {
        Int(try call(runtime, "Lorg/jsoup/select/Elements;", "size", "()I", receiver: elements).asInt32)
    }

    private func attribute(_ runtime: VMRuntime, _ element: VMValue, _ name: String) throws -> String? {
        runtime.stringValue(try call(
            runtime, "Lorg/jsoup/nodes/Element;", "attr", "(Ljava/lang/String;)Ljava/lang/String;",
            [runtime.newString(name)], receiver: element
        ))
    }

    private func newSet(_ runtime: VMRuntime) throws -> VMValue {
        let set = runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload())
        try runtime.invoke(try virtual(runtime, "Ljava/util/LinkedHashSet;", "<init>", "()V"), [set])
        return set
    }

    /// `CollectionsKt.addAll` is declared on `MutableCollection`; a set is a
    /// legal destination. It must keep its ties to the set payload instead of
    /// replacing it, otherwise the extension's union of detail elements is
    /// empty and the genre lookup dereferences null.
    func testAddAllKeepsSetDestinationAndSuppressesDuplicates() throws {
        let runtime = VMRuntime()
        let document = try parse(runtime, """
        <div class="row"><div>Genres:</div><div><a href="/genre/comedy">Comedy</a></div></div>\
        <div class="row"><div>Author:</div><div><a href="/search?author=1">One</a></div></div>
        """)
        let anchors = try select(runtime, document, "a[href]")
        XCTAssertEqual(try size(runtime, anchors), 2)

        let set = try newSet(runtime)
        let addAll = try static_(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "addAll", "(Ljava/util/Collection;Ljava/lang/Iterable;)Z"
        )
        XCTAssertTrue(try runtime.invoke(addAll, [set, anchors]).asBoolean)
        XCTAssertEqual(try call(runtime, "Ljava/util/LinkedHashSet;", "size", "()I", receiver: set).asInt32, 2)

        // A second pass over the same elements adds nothing, as on the JVM.
        XCTAssertFalse(try runtime.invoke(addAll, [set, anchors]).asBoolean)
        XCTAssertEqual(try call(runtime, "Ljava/util/LinkedHashSet;", "size", "()I", receiver: set).asInt32, 2)
    }

    /// The row scan unions `Map.keySet()` views, then compares the common
    /// ancestors of the collected elements. Both steps go through the same
    /// `addAll`, so the set must be populated from a key-set view too.
    func testAddAllFromKeySetViewPopulatesSet() throws {
        let runtime = VMRuntime()
        let document = try parse(runtime, """
        <div id="details"><div class="row">Genre: <a href="/genre/comedy">Comedy</a></div>\
        <div class="row">Genre: <a href="/genre/drama">Drama</a></div></div>
        """)
        let anchors = try select(runtime, document, "a[href]")
        let map = runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload())
        try runtime.invoke(try virtual(runtime, "Ljava/util/LinkedHashMap;", "<init>", "()V"), [map])
        let put = try virtual(runtime, "Ljava/util/HashMap;", "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;")
        for index in 0..<2 {
            let anchor = try call(
                runtime, "Lorg/jsoup/select/Elements;", "get", "(I)Ljava/lang/Object;", [.int32(Int32(index))],
                receiver: anchors
            )
            _ = try runtime.invoke(put, [map, anchor, runtime.newString("https://example.test/genre/\(index)")])
        }
        let keys = try call(runtime, "Ljava/util/HashMap;", "keySet", "()Ljava/util/Set;", receiver: map)
        let set = try newSet(runtime)
        _ = try runtime.invoke(
            try static_(
                runtime, "Lkotlin/collections/CollectionsKt;",
                "addAll", "(Ljava/util/Collection;Ljava/lang/Iterable;)Z"
            ),
            [set, keys]
        )
        XCTAssertEqual(try call(runtime, "Ljava/util/LinkedHashSet;", "size", "()I", receiver: set).asInt32, 2)
    }

    /// `input[name="chapter_ids[]"]`: the `]` inside the quoted value must not
    /// close the attribute selector. The chapter-list loop dereferences the
    /// element’s `value`, so a null match is the reported null pointer.
    func testAttributeSelectorIgnoresBracketsInsideQuotedValue() throws {
        let runtime = VMRuntime()
        let document = try parse(runtime, """
        <ol class="p-chapterList"><li class="p-chapterList_item">\
        <input type="checkbox" name="chapter_ids[]" value="1648275" disabled="disabled">\
        <a class="p-btn-chapter" href="/books/1/chapters/7">Chapter 7</a></li></ol>
        """)
        for selector in [
            "input[name=\"chapter_ids[]\"]",
            "input[name='chapter_ids[]']",
            "ol.p-chapterList li.p-chapterList_item input[name=\"chapter_ids[]\"]",
        ] {
            let input = try selectFirst(runtime, document, selector)
            XCTAssertTrue(input.bits != 0, "selector resolved to null: \(selector)")
            XCTAssertEqual(try attribute(runtime, input, "value"), "1648275", selector)
            XCTAssertEqual(try attribute(runtime, input, "name"), "chapter_ids[]", selector)
        }
    }

    /// A bracket inside a quoted value must also not end the attribute group
    /// during tokenisation, or the trailing descendant part is lost.
    func testDescendantAfterQuotedBracketValueStillMatches() throws {
        let runtime = VMRuntime()
        let document = try parse(runtime, """
        <div data-label="a]b"><span class="inner">hit</span></div>
        """)
        let elements = try select(runtime, document, "div[data-label=\"a]b\"] span.inner")
        XCTAssertEqual(try size(runtime, elements), 1)
    }

    /// After the row labels are read, `getMangaUpdate` walks
    /// `details.asSequence()` and destructures each element as a `Map.Entry`.
    /// The sequence must carry entries, not `Pair`s.
    func testMapAsSequenceYieldsMapEntries() throws {
        let runtime = VMRuntime()
        let map = runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload())
        try runtime.invoke(try virtual(runtime, "Ljava/util/LinkedHashMap;", "<init>", "()V"), [map])
        let put = try virtual(runtime, "Ljava/util/HashMap;", "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;")
        _ = try runtime.invoke(put, [map, runtime.newString("Genres:"), runtime.newString("Comedy")])
        _ = try runtime.invoke(put, [map, runtime.newString("Author:"), runtime.newString("One")])

        let sequence = try runtime.invoke(
            try static_(runtime, "Lkotlin/collections/MapsKt;", "asSequence", "(Ljava/util/Map;)Lkotlin/sequences/Sequence;"),
            [map]
        )
        let list = try runtime.invoke(
            try static_(runtime, "Lkotlin/sequences/SequencesKt;", "toList", "(Lkotlin/sequences/Sequence;)Ljava/util/List;"),
            [sequence]
        )
        let entries = try XCTUnwrap(runtime.listItems(list))
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            let payload = try XCTUnwrap(
                runtime.payload(entry, as: VMEntryPayload.self),
                "Map.asSequence must yield java.util.Map$Entry values"
            )
            XCTAssertFalse(runtime.stringValue(payload.key)?.isEmpty ?? true)
        }
    }

    /// The list parser may store the canonical page path in `SManga.memo`
    /// (`"path:..."`); `getMangaUpdate` then builds its details URL from it.
    /// The object cached by browse/search must be the one details receives,
    /// otherwise the engine falls back to an id-based URL and the request
    /// changes. After an arena recycle the rebuilt model must still carry the
    /// memo snapshot.
    func testCachedListMangaMemoReachesMangaUpdate() throws {
        let runtime = VMRuntime()
        let listed = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        runtime.manga(listed).url = runtime.newString("775")
        runtime.manga(listed).title = runtime.newString("Listed title")
        runtime.manga(listed).memo = runtime.makeNative(
            "Lkotlinx/serialization/json/JsonObject;",
            payload: VMJsonTree(.object(["path": VMJsonTree(.string("/book/canonical"))]))
        )

        var cache = MihonListMangaCache()
        cache.record(listed, runtime: runtime, sourceIndex: 3, generation: 7)

        let reused = cache.instance(
            runtime: runtime, sourceIndex: 3, url: "775", title: "Listed title", generation: 7
        )
        XCTAssertEqual(reused.bits, listed.bits, "details must reuse the list SManga instance")
        XCTAssertEqual(memoPath(runtime, reused), "/book/canonical")

        // Arena recycled: the cache keeps the memo snapshot, rebuilds the model.
        cache.invalidate()
        let rebuilt = cache.instance(
            runtime: runtime, sourceIndex: 3, url: "775", title: "Listed title", generation: 8
        )
        XCTAssertNotEqual(rebuilt.bits, listed.bits)
        XCTAssertEqual(memoPath(runtime, rebuilt), "/book/canonical")
        XCTAssertEqual(runtime.stringValue(runtime.manga(rebuilt).url), "775")
    }

    private func memoPath(_ runtime: VMRuntime, _ manga: VMValue) -> String? {
        guard let tree = runtime.payload(runtime.manga(manga).memo, as: VMJsonTree.self),
              case .object(let fields) = tree.kind else { return nil }
        return fields["path"]?.stringValue
    }
}
