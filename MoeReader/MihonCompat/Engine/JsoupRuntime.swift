//
//  JsoupRuntime.swift
//  MihonCompat
//
//  A dependency-free HTML parser and CSS selector engine. Extensions call
//  Jsoup.parse(...).select(...), read text/attributes, and walk the tree; this
//  implements that surface directly in Swift so no jsoup bytecode runs.
//

import Foundation

final class JNode {
    enum Kind {
        case document
        case element
        case text
        case comment
        case data
    }

    var kind: Kind
    var tag: String
    var attributes: [(String, String)]
    weak var parent: JNode?
    var children: [JNode]
    var text: String

    init(kind: Kind, tag: String = "", text: String = "", attributes: [(String, String)] = []) {
        self.kind = kind
        self.tag = tag
        self.text = text
        self.attributes = attributes
        self.children = []
    }

    var isElement: Bool { kind == .element }

    /// jsoup's text normalisation: whitespace runs collapse to one space and
    /// the edges are trimmed. Scanning characters avoids a regex match and
    /// UTF-16 range conversion per node, which dominated large-page
    /// `:contains` scans.
    static func collapsedWhitespace(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                if !output.isEmpty { pendingSpace = true }
            } else {
                if pendingSpace {
                    output.append(" ")
                    pendingSpace = false
                }
                output.append(character)
            }
        }
        return output
    }

    func attribute(_ name: String) -> String? {
        attributes.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    func setAttribute(_ name: String, _ value: String) {
        if let index = attributes.firstIndex(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) {
            attributes[index].1 = value
        } else {
            attributes.append((name, value))
        }
    }

    func removeAttribute(_ name: String) {
        attributes.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
    }

    var elementChildren: [JNode] { children.filter(\.isElement) }

    func descendants() -> [JNode] {
        var result: [JNode] = []
        var stack = children.reversed().map { $0 }
        while let node = stack.popLast() {
            if node.isElement {
                result.append(node)
                stack.append(contentsOf: node.children.reversed())
            }
        }
        return result
    }

    func textContent(ownOnly: Bool = false) -> String {
        var output = ""
        for child in children {
            switch child.kind {
            case .text, .data:
                output += child.text
            case .element:
                if ownOnly { continue }
                let childText = child.textContent()
                if !childText.isEmpty { output += childText }
                if JsoupHTML.blockTags.contains(child.tag) || child.tag == "br" { output += " " }
            default:
                break
            }
        }
        if ownOnly { return output }
        return JNode.collapsedWhitespace(output)
    }

    func outerHTML() -> String {
        switch kind {
        case .text:
            return JsoupHTML.escape(text)
        case .comment:
            return "<!--\(text)-->"
        case .data:
            return text
        case .document:
            return children.map { $0.outerHTML() }.joined()
        case .element:
            let attributes = attributes.map { " \($0.0)=\"\(JsoupHTML.escape($0.1))\"" }.joined()
            if JsoupHTML.voidTags.contains(tag) { return "<\(tag)\(attributes)>" }
            return "<\(tag)\(attributes)>\(children.map { $0.outerHTML() }.joined())</\(tag)>"
        }
    }

    func innerHTML() -> String {
        children.map { $0.outerHTML() }.joined()
    }

    /// jsoup's `hasText`: any descendant text that is not blank.
    var hasTextContent: Bool {
        switch kind {
        case .text, .data:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return children.contains { $0.hasTextContent }
        }
    }
}

final class JDocumentPayload {
    let root: JNode
    let baseUri: String
    init(root: JNode, baseUri: String) {
        self.root = root
        self.baseUri = baseUri
    }
}

final class JElementPayload {
    let node: JNode
    let document: JDocumentPayload
    init(node: JNode, document: JDocumentPayload) {
        self.node = node
        self.document = document
    }
}

final class JElementsPayload {
    let nodes: [JNode]
    let document: JDocumentPayload
    init(nodes: [JNode], document: JDocumentPayload) {
        self.nodes = nodes
        self.document = document
    }
}

enum JsoupHTML {
    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer",
        "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav",
        "ol", "p", "pre", "section", "table", "tr", "ul",
    ]

    static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    static let rawTags: Set<String> = ["script", "style"]

    static func escape(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: "&", with: "&amp;")
        output = output.replacingOccurrences(of: "<", with: "&lt;")
        output = output.replacingOccurrences(of: ">", with: "&gt;")
        output = output.replacingOccurrences(of: "\"", with: "&quot;")
        return output
    }

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "ldquo": "“", "rdquo": "”", "middot": "·", "bull": "•", "copy": "©",
        "reg": "®", "trade": "™", "deg": "°", "laquo": "«", "raquo": "»",
        "times": "×", "divide": "÷", "euro": "€", "pound": "£", "yen": "¥",
        "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡", "plusmn": "±",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character != "&" {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            guard let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 12 else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let body = String(text[text.index(after: index)..<semicolon])
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let value = UInt32(body.dropFirst(2), radix: 16), let scalar = UnicodeScalar(value) {
                    output.append(Character(scalar))
                    index = text.index(after: semicolon)
                    continue
                }
            } else if body.hasPrefix("#") {
                if let value = UInt32(body.dropFirst()), let scalar = UnicodeScalar(value) {
                    output.append(Character(scalar))
                    index = text.index(after: semicolon)
                    continue
                }
            } else if let decoded = entities[body] {
                output.append(decoded)
                index = text.index(after: semicolon)
                continue
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }

    static let autoClose: [String: Set<String>] = [
        "li": ["li"],
        "p": ["p"],
        "tr": ["tr", "td", "th"],
        "td": ["td", "th"],
        "th": ["td", "th"],
        "option": ["option"],
        "dt": ["dt", "dd"],
        "dd": ["dt", "dd"],
        "thead": ["tbody", "tfoot"],
        "tbody": ["tbody", "tfoot"],
        "tfoot": ["tbody"],
        "h1": ["h1", "h2", "h3", "h4", "h5", "h6"],
        "h2": ["h1", "h2", "h3", "h4", "h5", "h6"],
        "h3": ["h1", "h2", "h3", "h4", "h5", "h6"],
    ]

    /// jsoup's `abs:` resolution: absolute URLs are kept, protocol-relative
    /// URLs adopt the base scheme, and everything else resolves against the
    /// document base URI (`java.net.URL` semantics). Unresolvable input maps to
    /// the empty string, like jsoup.
    static func absoluteUrl(_ raw: String, base: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        if value.hasPrefix("//") {
            let scheme = base.hasPrefix("https") ? "https:" : "http:"
            return scheme + value
        }
        guard !base.isEmpty, let baseURL = URL(string: base),
              let resolved = URL(string: value, relativeTo: baseURL) else { return "" }
        return resolved.absoluteString
    }

    /// `Jsoup.parseBodyFragment`: the fragments land in a synthetic body element
    /// while the document keeps `html`/`head` wrappers, so `body()`, `select()`
    /// and `wholeText()` all observe the same tree as a full parse.
    static func parseBodyFragment(_ fragment: String, baseUri: String) -> JDocumentPayload {
        parse(fragment, baseUri: baseUri)
    }

    static func parse(_ html: String, baseUri: String) -> JDocumentPayload {
        let documentNode = JNode(kind: .document)
        let htmlElement = JNode(kind: .element, tag: "html")
        htmlElement.parent = documentNode
        documentNode.children.append(htmlElement)
        let head = JNode(kind: .element, tag: "head")
        head.parent = htmlElement
        htmlElement.children.append(head)
        let body = JNode(kind: .element, tag: "body")
        body.parent = htmlElement
        htmlElement.children.append(body)

        var stack: [JNode] = [body]
        var index = html.startIndex
        // Document preamble: `html`, `head`, `body` wrappers are implicit, and
        // metadata elements before body content belong in `head` (jsoup's
        // insertion mode), so `head meta[...]` selectors resolve.
        var inHead = true
        let headContentTags: Set<String> = ["base", "basefont", "bgsound", "link", "meta", "title", "style", "script", "noscript", "template"]

        func current() -> JNode { stack.last ?? body }
        func appendText(_ text: String) {
            let decoded = decodeEntities(text)
            guard !decoded.isEmpty else { return }
            if inHead, stack.count == 1 {
                if decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                inHead = false
            }
            let node = JNode(kind: .text, text: decoded)
            node.parent = current()
            current().children.append(node)
        }

        while index < html.endIndex {
            if html[index] == "<" {
                let remainder = html[index...]
                if remainder.hasPrefix("<!--") {
                    if let end = html.range(of: "-->", range: index..<html.endIndex) {
                        let text = String(html[html.index(index, offsetBy: 4)..<end.lowerBound])
                        let node = JNode(kind: .comment, text: text)
                        node.parent = current()
                        current().children.append(node)
                        index = end.upperBound
                        continue
                    }
                }
                if remainder.hasPrefix("<!") || remainder.hasPrefix("<?") {
                    if let end = html.range(of: ">", range: index..<html.endIndex) {
                        index = end.upperBound
                        continue
                    }
                    break
                }
                if remainder.hasPrefix("</") {
                    guard let end = html.range(of: ">", range: index..<html.endIndex) else { break }
                    let name = String(html[html.index(index, offsetBy: 2)..<end.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let target = stack.lastIndex(where: { $0.tag == name }) {
                        stack.removeSubrange(target..<stack.count)
                    }
                    index = end.upperBound
                    continue
                }
                guard let end = html.range(of: ">", range: index..<html.endIndex) else { break }
                let rawTag = String(html[html.index(after: index)..<end.lowerBound])
                let selfClosing = rawTag.hasSuffix("/")
                let content = selfClosing ? String(rawTag.dropLast()) : rawTag
                let tokenizer = JsoupHTML.TagTokenizer(content)
                let tag = tokenizer.name.lowercased()
                if tag.isEmpty {
                    appendText("<")
                    index = html.index(after: index)
                    continue
                }
                index = end.upperBound

                if tag == "html" || tag == "head" {
                    continue
                }
                if tag == "body" {
                    inHead = false
                    continue
                }

                if !selfClosing, let closes = autoClose[tag] {
                    while let top = stack.last, closes.contains(top.tag), stack.count > 1 {
                        stack.removeLast()
                    }
                }
                if let top = stack.last, top.tag == "p", tag != "p" && tag != "a" {
                    if ["div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "form"].contains(tag) {
                        stack.removeLast()
                    }
                }

                let parent: JNode
                if inHead, stack.count == 1, headContentTags.contains(tag) {
                    parent = head
                } else {
                    inHead = false
                    parent = current()
                }
                let element = JNode(kind: .element, tag: tag, attributes: tokenizer.attributes)
                element.parent = parent
                parent.children.append(element)

                if !selfClosing, !voidTags.contains(tag) {
                    if rawTags.contains(tag) {
                        let closing = "</\(tag)"
                        if let closeRange = html.range(of: closing, options: .caseInsensitive, range: index..<html.endIndex) {
                            let text = String(html[index..<closeRange.lowerBound])
                            let textNode = JNode(kind: .data, text: text)
                            textNode.parent = element
                            element.children.append(textNode)
                            if let gt = html.range(of: ">", range: closeRange.lowerBound..<html.endIndex) {
                                index = gt.upperBound
                            } else {
                                index = html.endIndex
                            }
                        } else {
                            let text = String(html[index...])
                            let textNode = JNode(kind: .data, text: text)
                            textNode.parent = element
                            element.children.append(textNode)
                            index = html.endIndex
                        }
                        continue
                    }
                    stack.append(element)
                }
                continue
            }

            guard let nextTag = html[index...].firstIndex(of: "<") else {
                appendText(String(html[index...]))
                break
            }
            appendText(String(html[index..<nextTag]))
            index = nextTag
        }

        // Move head-only elements out of body when the document is complete.
        if body.children.contains(where: { $0.tag == "html" || $0.tag == "head" || $0.tag == "body" }) {
            // Nested html documents: flatten into the synthetic body.
            var flattened: [JNode] = []
            var queue = body.children
            while !queue.isEmpty {
                let node = queue.removeFirst()
                if node.isElement, node.tag == "html" || node.tag == "head" || node.tag == "body" {
                    queue.insert(contentsOf: node.children, at: 0)
                } else {
                    node.parent = body
                    flattened.append(node)
                }
            }
            body.children = flattened
        }

        return JDocumentPayload(root: documentNode, baseUri: baseUri)
    }
}

extension JsoupHTML {
    struct TagTokenizer {
        var name = ""
        var attributes: [(String, String)] = []

        init(_ content: String) {
            var index = content.startIndex
            while index < content.endIndex, !content[index].isWhitespace, content[index] != "/" {
                name.append(content[index])
                index = content.index(after: index)
            }
            var currentName: String?
            var currentValue = ""
            var inQuote: Character?
            var expectingValue = false
            var buffer = ""
            while index < content.endIndex {
                let character = content[index]
                index = content.index(after: index)
                if let quote = inQuote {
                    if character == quote {
                        inQuote = nil
                        if let name = currentName {
                            attributes.append((name, decodeEntities(currentValue)))
                        }
                        currentName = nil
                        currentValue = ""
                        expectingValue = false
                    } else {
                        currentValue.append(character)
                    }
                    continue
                }
                if character == "\"" || character == "'" {
                    inQuote = character
                    continue
                }
                if character == "=" {
                    expectingValue = true
                    currentName = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer = ""
                    continue
                }
                if character.isWhitespace {
                    if !buffer.isEmpty {
                        if expectingValue {
                            currentValue += buffer
                            buffer = ""
                        } else if let name = currentName {
                            attributes.append((name, currentValue))
                            currentName = nil
                            currentValue = ""
                        } else {
                            attributes.append((buffer, ""))
                            buffer = ""
                        }
                    } else if expectingValue {
                        // value continues after whitespace
                    }
                    continue
                }
                buffer.append(character)
            }
            if !buffer.isEmpty {
                if expectingValue, let name = currentName {
                    attributes.append((name, decodeEntities(buffer)))
                } else {
                    attributes.append((buffer, ""))
                }
            } else if expectingValue, let name = currentName {
                attributes.append((name, ""))
            }
        }
    }
}

// MARK: - Selectors

struct JsoupSelector {
    struct AttributeConstraint {
        var name: String
        var op: String
        var value: String?
        /// Compiled pattern for jsoup's `~=` (regex match) operator.
        var regex: NSRegularExpression?
    }

    struct Pseudo {
        /// Lowercased pseudo-class name.
        var name: String
        /// Raw argument text between the parentheses.
        var argument: String?
        /// `:contains*` needle: quote-trimmed and lowercased once, at parse time.
        var needle: String? = nil
        /// Compiled pattern for `:matches` / `:matchesown`.
        var regex: NSRegularExpression? = nil
        /// Parsed argument for `:not`, `:is`, `:has`.
        var inner: [Complex]? = nil
        /// `:has(> ...)`: only direct children can match.
        var childScoped = false
        /// `:has(...)` whose argument ends in a set-level positional filter needs
        /// per-candidate evaluation to keep `select` semantics.
        var innerHasPositional = false
        /// This pseudo filters the matched set (`:first`, `:eq(2)`, ...).
        var isPositional = false
        /// Pre-parsed `:nth-child` formula.
        var nth: (Int, Int)? = nil
    }

    struct Compound {
        var tag: String?
        var ids: [String] = []
        var classes: [String] = []
        var attributes: [AttributeConstraint] = []
        var pseudos: [Pseudo] = []
    }

    struct Complex {
        var compounds: [Compound]
        var combinators: [Character]
    }

    /// State for one `select`/`matches` evaluation. Everything expensive is
    /// computed at most once per node and dropped when the call returns:
    ///
    /// - normalized text, built bottom-up so a parent reuses the cached text of
    ///   its children instead of re-walking every subtree;
    /// - class splits;
    /// - `:has(...)` answer sets, so the inner selector is evaluated over the
    ///   document once instead of once per candidate element.
    ///
    /// The owning runtime honours the per-operation deadline, so a pathological
    /// page aborts with `VMCallTimeout` instead of blocking the host thread.
    final class Context {
        let root: JNode
        let runtime: VMRuntime?
        /// Topmost node of the tree. `:has` scans this whole tree because a
        /// selector can test an ancestor of `root` (descendant combinators).
        let scanRoot: JNode

        private var texts: [ObjectIdentifier: String] = [:]
        private var lowerTexts: [ObjectIdentifier: String] = [:]
        private var ownTexts: [ObjectIdentifier: String] = [:]
        private var lowerOwnTexts: [ObjectIdentifier: String] = [:]
        private var dataTexts: [ObjectIdentifier: String] = [:]
        private var classLists: [ObjectIdentifier: [String]] = [:]
        private var descendantHas: [String: Set<ObjectIdentifier>] = [:]
        private var childHas: [String: Set<ObjectIdentifier>] = [:]
        private var ticks = 0

        init(root: JNode, runtime: VMRuntime?) {
            self.root = root
            self.runtime = runtime
            var top = root
            while let parent = top.parent { top = parent }
            self.scanRoot = top
        }

        /// Bounded-work probe: one deadline check per few hundred nodes keeps the
        /// clock syscall off the hot path while still aborting a runaway select.
        func tick() throws {
            guard let runtime else { return }
            ticks += 1
            guard ticks >= 512 else { return }
            ticks = 0
            try runtime.checkOperationDeadline()
        }

        /// jsoup `Element.text()` for `node`, memoized bottom-up.
        func text(of node: JNode) -> String {
            let key = ObjectIdentifier(node)
            if let cached = texts[key] { return cached }
            var output = ""
            for child in node.children {
                switch child.kind {
                case .text, .data:
                    output += child.text
                case .element:
                    let childText = text(of: child)
                    if !childText.isEmpty { output += childText }
                    if JsoupHTML.blockTags.contains(child.tag) || child.tag == "br" { output += " " }
                default:
                    break
                }
            }
            let value = JNode.collapsedWhitespace(output)
            texts[key] = value
            return value
        }

        func lowerText(of node: JNode) -> String {
            let key = ObjectIdentifier(node)
            if let cached = lowerTexts[key] { return cached }
            let value = text(of: node).lowercased()
            lowerTexts[key] = value
            return value
        }

        func ownText(of node: JNode) -> String {
            let key = ObjectIdentifier(node)
            if let cached = ownTexts[key] { return cached }
            var output = ""
            for child in node.children {
                switch child.kind {
                case .text, .data: output += child.text
                default: break
                }
            }
            ownTexts[key] = output
            return output
        }

        func lowerOwnText(of node: JNode) -> String {
            let key = ObjectIdentifier(node)
            if let cached = lowerOwnTexts[key] { return cached }
            let value = ownText(of: node).lowercased()
            lowerOwnTexts[key] = value
            return value
        }

        func lowerDataText(of node: JNode) -> String {
            let key = ObjectIdentifier(node)
            if let cached = dataTexts[key] { return cached }
            var data = ""
            for child in node.children where child.kind == .data || child.kind == .text {
                data += child.text
            }
            let value = data.lowercased()
            dataTexts[key] = value
            return value
        }

        func classList(of node: JNode) -> [String] {
            let key = ObjectIdentifier(node)
            if let cached = classLists[key] { return cached }
            let value = (node.attribute("class") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
            classLists[key] = value
            return value
        }

        /// Every node that has a descendant matching the `:has` argument.
        func ancestorsWithMatchingDescendant(key: String, groups: [Complex]) throws -> Set<ObjectIdentifier> {
            if let cached = descendantHas[key] { return cached }
            var ancestors: Set<ObjectIdentifier> = []
            for candidate in scanRoot.descendants() {
                try tick()
                guard try JsoupSelector.anyMatch(candidate, groups: groups, self) else { continue }
                var cursor = candidate.parent
                while let parent = cursor {
                    ancestors.insert(ObjectIdentifier(parent))
                    cursor = parent.parent
                }
            }
            descendantHas[key] = ancestors
            return ancestors
        }

        /// Parents with an element child matching the `:has(> ...)` argument.
        func parentsWithMatchingChild(key: String, groups: [Complex]) throws -> Set<ObjectIdentifier> {
            if let cached = childHas[key] { return cached }
            var parents: Set<ObjectIdentifier> = []
            for candidate in scanRoot.descendants() {
                try tick()
                guard try JsoupSelector.anyMatch(candidate, groups: groups, self) else { continue }
                if let parent = candidate.parent { parents.insert(ObjectIdentifier(parent)) }
            }
            childHas[key] = parents
            return parents
        }
    }

    /// Parsed selector ASTs, keyed by source text. Selectors repeat heavily and
    /// parsing is pure.
    nonisolated(unsafe) private static var parsedCache: [String: [Complex]] = [:]

    /// Compiled patterns for `:matches` and `[attr~=]`, shared between selector
    /// strings that use the same pattern.
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        if regexCache.count > 256 { regexCache.removeAll(keepingCapacity: true) }
        regexCache[pattern] = expression
        return expression
    }

    static func parsed(_ selector: String) -> [Complex] {
        if let cached = parsedCache[selector] { return cached }
        let value = parse(selector)
        if parsedCache.count > 512 { parsedCache.removeAll(keepingCapacity: true) }
        parsedCache[selector] = value
        return value
    }

    static func matches(_ node: JNode, selector: String) -> Bool {
        (try? matches(node, selector: selector, runtime: nil)) ?? false
    }

    static func matches(_ node: JNode, selector: String, runtime: VMRuntime?) throws -> Bool {
        let groups = parsed(selector)
        guard !groups.isEmpty else { return false }
        return try anyMatch(node, groups: groups, Context(root: node, runtime: runtime))
    }

    static func select(_ root: JNode, selector: String) -> [JNode] {
        let groups = parsed(selector)
        guard !groups.isEmpty else { return [] }
        return (try? select(groups: groups, context: Context(root: root, runtime: nil))) ?? []
    }

    static func select(_ root: JNode, selector: String, runtime: VMRuntime?) throws -> [JNode] {
        let groups = parsed(selector)
        guard !groups.isEmpty else { return [] }
        return try select(groups: groups, context: Context(root: root, runtime: runtime))
    }

    static func select(groups: [Complex], context: Context) throws -> [JNode] {
        let candidates = context.root.descendants()
        var selected = Set<ObjectIdentifier>()
        var result: [JNode] = []
        for group in groups {
            var matched: [JNode] = []
            for node in candidates {
                try context.tick()
                if try match(node, group, context) { matched.append(node) }
            }
            matched = applyPositionalFilters(matched, group.compounds.last?.pseudos ?? [])
            for node in matched where selected.insert(ObjectIdentifier(node)).inserted {
                result.append(node)
            }
        }
        guard groups.count > 1 else { return result }
        // Union of several selector groups keeps document order.
        var order: [ObjectIdentifier: Int] = [:]
        for (index, node) in candidates.enumerated() { order[ObjectIdentifier(node)] = index }
        return result.sorted { (order[ObjectIdentifier($0)] ?? 0) < (order[ObjectIdentifier($1)] ?? 0) }
    }

    static func anyMatch(_ node: JNode, groups: [Complex], _ context: Context) throws -> Bool {
        for group in groups {
            if try match(node, group, context) { return true }
        }
        return false
    }

    private static func applyPositionalFilters(_ nodes: [JNode], _ pseudos: [Pseudo]) -> [JNode] {
        var values = nodes
        for pseudo in pseudos where pseudo.isPositional {
            switch pseudo.name {
            case "first": values = Array(values.prefix(1))
            case "last": values = values.isEmpty ? [] : [values[values.count - 1]]
            case "eq":
                if let index = pseudo.argument.flatMap(Int.init) {
                    values = index >= 0 && index < values.count ? [values[index]] : []
                }
            case "gt":
                if let index = pseudo.argument.flatMap(Int.init) {
                    values = index + 1 < values.count ? Array(values[(index + 1)...]) : []
                }
            case "lt":
                if let index = pseudo.argument.flatMap(Int.init) {
                    values = index > 0 ? Array(values.prefix(index)) : []
                }
            case "even": values = values.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            case "odd": values = values.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            default: break
            }
        }
        return values
    }

    static func parse(_ selector: String) -> [Complex] {
        var groups: [Complex] = []
        var current = Complex(compounds: [], combinators: [])
        var buffer = ""
        var bracketDepth = 0
        var parenDepth = 0
        var pendingCombinator: Character?
        let characters = Array(selector)
        var index = 0

        func flushCompound() {
            guard !buffer.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if let combinator = pendingCombinator {
                current.combinators.append(combinator)
            } else if !current.compounds.isEmpty {
                current.combinators.append(" ")
            }
            current.compounds.append(parseCompound(buffer))
            buffer = ""
            pendingCombinator = nil
        }

        while index < characters.count {
            let character = characters[index]
            if character == "[" { bracketDepth += 1; buffer.append(character); index += 1; continue }
            if character == "]" { bracketDepth = max(0, bracketDepth - 1); buffer.append(character); index += 1; continue }
            if character == "(" { parenDepth += 1; buffer.append(character); index += 1; continue }
            if character == ")" { parenDepth = max(0, parenDepth - 1); buffer.append(character); index += 1; continue }
            if bracketDepth == 0, parenDepth == 0 {
                if character == "," {
                    flushCompound()
                    if !current.compounds.isEmpty { groups.append(current) }
                    current = Complex(compounds: [], combinators: [])
                    index += 1
                    continue
                }
                if character == ">" || character == "+" || character == "~" {
                    flushCompound()
                    pendingCombinator = character
                    index += 1
                    continue
                }
                if character.isWhitespace {
                    flushCompound()
                    index += 1
                    continue
                }
            }
            buffer.append(character)
            index += 1
        }
        flushCompound()
        if !current.compounds.isEmpty { groups.append(current) }
        return groups
    }

    static func parseCompound(_ text: String) -> Compound {
        var compound = Compound()
        var index = text.startIndex
        var buffer = ""
        var mode: Character = "t"

        func flushTag() {
            if !buffer.isEmpty {
                let value = buffer
                if value != "*" { compound.tag = value.lowercased() }
                buffer = ""
            }
        }

        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "#", ".", "[", ":":
                if mode == "t" { flushTag() }
                if character == "[" {
                    guard let end = text[index...].firstIndex(of: "]") else {
                        index = text.index(after: index)
                        continue
                    }
                    let body = String(text[text.index(after: index)..<end])
                    compound.attributes.append(parseAttribute(body))
                    index = text.index(after: end)
                    mode = "t"
                    continue
                }
                if character == ":" {
                    var cursor = text.index(after: index)
                    var name = ""
                    while cursor < text.endIndex, text[cursor] != "(", text[cursor] != ")",
                          !"#.[:".contains(text[cursor]) {
                        name.append(text[cursor])
                        cursor = text.index(after: cursor)
                    }
                    var argument: String?
                    if cursor < text.endIndex, text[cursor] == "(" {
                        var depth = 0
                        let start = text.index(after: cursor)
                        var end = start
                        while end < text.endIndex {
                            let inner = text[end]
                            if inner == "(" {
                                depth += 1
                            } else if inner == ")" {
                                if depth == 0 { break }
                                depth -= 1
                            }
                            end = text.index(after: end)
                        }
                        argument = String(text[start..<end])
                        cursor = end < text.endIndex ? text.index(after: end) : end
                    }
                    compound.pseudos.append(makePseudo(name, argument))
                    index = cursor
                    mode = "t"
                    continue
                }
                mode = character
                index = text.index(after: index)
            default:
                buffer.append(character)
                index = text.index(after: index)
                // Flush single-character selector kinds lazily when next delimiter arrives.
                if mode == "#" || mode == "." {
                    let nextIsDelimiter = index >= text.endIndex || "#.[:".contains(text[index])
                    if nextIsDelimiter {
                        if mode == "#" { compound.ids.append(buffer) } else { compound.classes.append(buffer) }
                        buffer = ""
                        mode = "t"
                    }
                }
            }
        }
        if mode == "t" { flushTag() }
        return compound
    }

    /// Resolves everything a pseudo needs once, when the selector is parsed:
    /// lowercased name and needle, compiled regex, parsed inner selector and
    /// parsed `an+b` formula.
    static func makePseudo(_ rawName: String, _ argument: String?) -> Pseudo {
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        var pseudo = Pseudo(name: name, argument: argument)
        switch name {
        case "contains", "containsown", "containsdata":
            pseudo.needle = (argument ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        case "matches", "matchesown":
            pseudo.regex = argument.flatMap { compiledRegex($0) }
        case "not", "is":
            pseudo.inner = argument.map { parse($0) }
        case "has":
            guard let argument else { return pseudo }
            if argument.hasPrefix(">") {
                let childSelector = String(argument.dropFirst()).trimmingCharacters(in: .whitespaces)
                pseudo.childScoped = true
                pseudo.inner = parse(childSelector)
            } else {
                pseudo.inner = parse(argument)
            }
            pseudo.innerHasPositional = (pseudo.inner ?? []).contains { group in
                (group.compounds.last?.pseudos ?? []).contains { $0.isPositional }
            }
        case "nth-child":
            pseudo.nth = argument.flatMap(parseNth)
        case "first", "last", "eq", "gt", "lt", "even", "odd":
            pseudo.isPositional = true
        default:
            break
        }
        return pseudo
    }

    static func parseAttribute(_ body: String) -> AttributeConstraint {
        let patterns = ["^=", "$=", "*=", "~=", "|=", "="]
        for pattern in patterns {
            if let range = body.range(of: pattern) {
                let name = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var value = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return AttributeConstraint(
                    name: name,
                    op: pattern,
                    value: value,
                    regex: pattern == "~=" ? compiledRegex(value) : nil
                )
            }
        }
        return AttributeConstraint(name: body.trimmingCharacters(in: .whitespaces), op: "", value: nil, regex: nil)
    }

    static func match(_ node: JNode, _ complex: Complex, _ context: Context) throws -> Bool {
        guard !complex.compounds.isEmpty else { return false }
        return try matchAt(node, complex, index: complex.compounds.count - 1, context)
    }

    private static func matchAt(_ node: JNode, _ complex: Complex, index: Int, _ context: Context) throws -> Bool {
        guard node.isElement, try matchCompound(node, complex.compounds[index], context) else { return false }
        if index == 0 { return true }
        let combinator = complex.combinators[index - 1]
        switch combinator {
        case ">":
            guard let parent = node.parent else { return false }
            return try matchAt(parent, complex, index: index - 1, context)
        case "+":
            guard let previous = previousElement(node) else { return false }
            return try matchAt(previous, complex, index: index - 1, context)
        case "~":
            var cursor = previousElement(node)
            while let sibling = cursor {
                if try matchAt(sibling, complex, index: index - 1, context) { return true }
                cursor = previousElement(sibling)
            }
            return false
        default:
            var cursor = node.parent
            while let parent = cursor {
                if parent.isElement, try matchAt(parent, complex, index: index - 1, context) { return true }
                cursor = parent.parent
            }
            return false
        }
    }

    static func nextElement(_ node: JNode) -> JNode? {
        guard let parent = node.parent, let index = parent.children.firstIndex(where: { $0 === node }) else { return nil }
        var cursor = index + 1
        while cursor < parent.children.count {
            if parent.children[cursor].isElement { return parent.children[cursor] }
            cursor += 1
        }
        return nil
    }

    private static func previousElement(_ node: JNode) -> JNode? {
        guard let parent = node.parent, let index = parent.children.firstIndex(where: { $0 === node }) else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            if parent.children[cursor].isElement { return parent.children[cursor] }
            cursor -= 1
        }
        return nil
    }

    private static func regexMatches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    static func matchCompound(_ node: JNode, _ compound: Compound, _ context: Context) throws -> Bool {
        if let tag = compound.tag, node.tag != tag { return false }
        if !compound.ids.isEmpty {
            let id = node.attribute("id") ?? ""
            for expected in compound.ids where id != expected { return false }
        }
        if !compound.classes.isEmpty {
            let classes = context.classList(of: node)
            for expected in compound.classes where !classes.contains(expected) { return false }
        }
        for attribute in compound.attributes {
            guard let actual = node.attribute(attribute.name) else { return false }
            switch attribute.op {
            case "=": if actual != (attribute.value ?? "") { return false }
            case "^=": if !actual.hasPrefix(attribute.value ?? "") { return false }
            case "$=": if !actual.hasSuffix(attribute.value ?? "") { return false }
            case "*=": if !actual.contains(attribute.value ?? "") { return false }
            case "~=":
                // jsoup redefines `~=` as a regex match on the value (CSS-Word
                // containment is not offered), so `[x-data~=scroll]` matches
                // any value containing "scroll".
                guard let regex = attribute.regex, regexMatches(regex, actual) else { return false }
            case "|=": if actual != (attribute.value ?? "") && !actual.hasPrefix((attribute.value ?? "") + "-") { return false }
            default: break
            }
        }
        for pseudo in compound.pseudos {
            if !(try matchPseudo(node, pseudo, context)) { return false }
        }
        return true
    }

    static func matchPseudo(_ node: JNode, _ pseudo: Pseudo, _ context: Context) throws -> Bool {
        switch pseudo.name {
        case "first-child":
            return siblingInfo(node).index == 0
        case "last-child":
            let info = siblingInfo(node)
            return info.count > 0 && info.index == info.count - 1
        case "only-child":
            return siblingInfo(node).count == 1
        case "empty":
            return !node.children.contains(where: { $0.isElement }) && context.text(of: node).isEmpty
        case "root":
            return node.parent?.kind == .document
        case "not":
            guard let inner = pseudo.inner else { return true }
            return !(try anyMatch(node, groups: inner, context))
        case "has":
            guard let inner = pseudo.inner, !inner.isEmpty else { return false }
            // `:has(> x)` only inspects children, so the full-subtree scan
            // (quadratic on pages with many sibling rows) is unnecessary.
            if pseudo.childScoped {
                let parents = try context.parentsWithMatchingChild(key: pseudo.argument ?? "", groups: inner)
                return parents.contains(ObjectIdentifier(node))
            }
            // The inner selector is evaluated once over the document and its
            // matches are folded into the set of ancestors; asking per
            // candidate would walk every descendant subtree again.
            if pseudo.innerHasPositional {
                return try hasDescendantScoped(node, groups: inner, context)
            }
            let ancestors = try context.ancestorsWithMatchingDescendant(key: pseudo.argument ?? "", groups: inner)
            return ancestors.contains(ObjectIdentifier(node))
        case "contains":
            return context.lowerText(of: node).contains(pseudo.needle ?? "")
        case "containsown":
            return context.lowerOwnText(of: node).contains(pseudo.needle ?? "")
        case "containsdata":
            // jsoup: the combined data of the element's direct data nodes
            // (script/style bodies are stored as data nodes).
            return context.lowerDataText(of: node).contains(pseudo.needle ?? "")
        case "matches":
            guard let regex = pseudo.regex else { return false }
            return regexMatches(regex, context.text(of: node))
        case "matchesown":
            guard let regex = pseudo.regex else { return false }
            return regexMatches(regex, context.ownText(of: node))
        case "is":
            // jsoup 1.16+: `:is(...)` is `:matches` with selector syntax.
            guard let inner = pseudo.inner else { return false }
            return try anyMatch(node, groups: inner, context)
        case "nth-child":
            guard let (a, b) = pseudo.nth else { return false }
            let position = siblingInfo(node).index + 1
            if a == 0 { return position == b }
            return position >= b && (position - b) % a == 0 && (position - b) / a >= 0
        case "first-of-type":
            return isFirstOfType(node)
        case "last-of-type":
            return isLastOfType(node)
        case "header":
            return ["h1", "h2", "h3", "h4", "h5", "h6"].contains(node.tag)
        case "parent":
            return !node.children.isEmpty
        case "first", "last", "eq", "gt", "lt", "even", "odd":
            // Applied to the matched set by `select`, not per element.
            return true
        default:
            return false
        }
    }

    /// Element index among its parent's element children, and that count.
    private static func siblingInfo(_ node: JNode) -> (index: Int, count: Int) {
        guard let parent = node.parent else { return (0, 1) }
        var index = 0
        var count = 0
        for child in parent.children where child.isElement {
            if child === node { index = count }
            count += 1
        }
        return (index, count)
    }

    private static func isFirstOfType(_ node: JNode) -> Bool {
        guard let parent = node.parent else { return true }
        for child in parent.children where child.isElement {
            if child.tag == node.tag { return child === node }
        }
        return false
    }

    private static func isLastOfType(_ node: JNode) -> Bool {
        guard let parent = node.parent else { return true }
        var last: JNode?
        for child in parent.children where child.isElement {
            if child.tag == node.tag { last = child }
        }
        return last === node
    }

    /// Legacy `:has` semantics for arguments that end in a set-level positional
    /// pseudo (`:eq(1)`, `:gt(0)`, ...): the inner selector is applied to each
    /// candidate's own subtree and filtered there.
    private static func hasDescendantScoped(_ node: JNode, groups: [Complex], _ context: Context) throws -> Bool {
        let candidates = node.descendants()
        for group in groups {
            let pseudos = group.compounds.last?.pseudos ?? []
            if pseudos.contains(where: { $0.isPositional }) {
                var matched: [JNode] = []
                for candidate in candidates {
                    try context.tick()
                    if try match(candidate, group, context) { matched.append(candidate) }
                }
                if !applyPositionalFilters(matched, pseudos).isEmpty { return true }
            } else {
                for candidate in candidates {
                    try context.tick()
                    if try match(candidate, group, context) { return true }
                }
            }
        }
        return false
    }

    static func parseNth(_ text: String) -> (Int, Int)? {
        let value = text.replacingOccurrences(of: " ", with: "").lowercased()
        if value == "even" { return (2, 0) }
        if value == "odd" { return (2, 1) }
        if let number = Int(value) { return (0, number) }
        guard let nIndex = value.firstIndex(of: "n") else { return nil }
        let aText = String(value[..<nIndex])
        let a = aText.isEmpty || aText == "+" ? 1 : (aText == "-" ? -1 : (Int(aText) ?? 1))
        var rest = String(value[value.index(after: nIndex)...])
        if rest.isEmpty { return (a, 0) }
        if rest.hasPrefix("+") { rest.removeFirst() }
        guard let b = Int(rest) else { return nil }
        return (a, b)
    }
}

// MARK: - Runtime classes

enum JsoupRuntime {
    /// `android.text.Html`: markup to plain text through the same tokenizer.
    private static func htmlClasses() -> [NativeClass] {
        let spanned = NativeClass("Landroid/text/Spanned;", superclass: nil, interfaces: ["Ljava/lang/CharSequence;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        let html = NativeClass("Landroid/text/Html;")
        for signature in ["(Ljava/lang/String;)Landroid/text/Spanned;", "(Ljava/lang/String;I)Landroid/text/Spanned;"] {
            html.staticMethod("fromHtml", signature) { runtime, args, _ in
                // The text-page interceptor only reads `toString()`, so a plain
                // string carries the extracted text unchanged.
                runtime.newString(plainText(fromHtml: runtime.stringValue(args[0]) ?? ""))
            }
        }
        return [html, spanned]
    }

    static func plainText(fromHtml markup: String) -> String {
        let document = JsoupHTML.parse(markup, baseUri: "")
        var output = ""
        func walk(_ node: JNode) {
            if node.kind == .element {
                let tag = node.tag
                if tag == "br" {
                    output += "\n"
                    return
                }
                let block = JsoupHTML.blockTags.contains(tag) || tag == "div" || tag == "p"
                if block, !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
                for child in node.children { walk(child) }
                if block, !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
                return
            }
            if node.kind == .text { output += node.text }
        }
        walk(document.root)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += htmlClasses()
        result += elementClasses().flatMap { $0 }
        result += elementsClasses().flatMap { $0 }
        result += textNodeClasses().flatMap { $0 }
        result += attributesClasses().flatMap { $0 }
        result += parseClasses().flatMap { $0 }
        return result
    }

    private static func elementClasses() -> [[NativeClass]] {
        let element = NativeClass("Lorg/jsoup/nodes/Element;", superclass: "Lorg/jsoup/nodes/Node;")
        element.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let tag = (runtime.stringValue(args[1]) ?? "").lowercased()
            let document = JsoupHTML.parse("", baseUri: "")
            let node = JNode(kind: .element, tag: tag)
            runtime.setPayload(args[0], JElementPayload(node: node, document: document))
            return .zero
        }
        element.method("<init>", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            let tag = (runtime.stringValue(args[1]) ?? "").lowercased()
            let document = JsoupHTML.parse("", baseUri: runtime.stringValue(args[2]) ?? "")
            let node = JNode(kind: .element, tag: tag)
            runtime.setPayload(args[0], JElementPayload(node: node, document: document))
            return .zero
        }
        registerElementMethods(element)

        let document = NativeClass("Lorg/jsoup/nodes/Document;", superclass: "Lorg/jsoup/nodes/Element;")
        document.method("title", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let title = payload.node.descendants().first(where: { $0.tag == "title" }) else { return runtime.newString("") }
            return runtime.newString(title.textContent())
        }
        document.method("head", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let head = payload.node.descendants().first(where: { $0.tag == "head" }) else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: head, document: payload.document))
        }
        document.method("body", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let body = payload.node.descendants().first(where: { $0.tag == "body" }) else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: body, document: payload.document))
        }
        document.method("location", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: JElementPayload.self)?.document.baseUri ?? "")
        }
        document.method("title", "(Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            if let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) {
                if let title = payload.node.descendants().first(where: { $0.tag == "title" }) {
                    title.children.removeAll()
                    let text = JNode(kind: .text, text: runtime.stringValue(args[1]) ?? "")
                    text.parent = title
                    title.children.append(text)
                }
            }
            return args[0]
        }

        let node = NativeClass("Lorg/jsoup/nodes/Node;", superclass: "Ljava/lang/Object;")
        node.method("nodeName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.tag)
        }
        node.method("outerHtml", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.outerHTML())
        }
        node.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.outerHTML())
        }
        node.method("parent", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let parent = payload.node.parent, parent.isElement else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: parent, document: payload.document))
        }
        node.method("ownerDocument", "()Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: payload.document.root, document: payload.document))
        }
        node.method("baseUri", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.document.baseUri)
        }
        node.method("remove", "()V") { runtime, args, _ in
            if let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
               let parent = payload.node.parent,
               let index = parent.children.firstIndex(where: { $0 === payload.node }) {
                parent.children.remove(at: index)
            }
            return .zero
        }
        node.method("childNodeSize", "()I") { runtime, args, _ in
            let payload: JElementPayload? = runtime.payload(args[0], as: JElementPayload.self)
            return .int32(Int32(payload?.node.children.count ?? 0))
        }
        return [[element, node, document]]
    }

    private static func registerElementMethods(_ element: NativeClass) {
        element.method("tagName", "()Ljava/lang/String;") { runtime, args, _ in JsoupRuntime.string(runtime, args[0], \.tag) }
        element.method("normalName", "()Ljava/lang/String;") { runtime, args, _ in JsoupRuntime.string(runtime, args[0], \.tag) }
        element.method("id", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.attribute("id") ?? "")
        }
        element.method("className", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.attribute("class") ?? "")
        }
        element.method("classNames", "()Ljava/util/Set;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let classes = (payload.node.attribute("class") ?? "").split(whereSeparator: { $0.isWhitespace }).map { runtime.newString(String($0)) }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(classes))
        }
        element.method("hasClass", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .boolean(false) }
            let classes = (payload.node.attribute("class") ?? "").split(whereSeparator: { $0.isWhitespace })
            return .boolean(classes.contains(Substring(runtime.stringValue(args[1]) ?? "")))
        }
        element.method("addClass", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return args[0] }
            payload.node.setAttribute("class", ((payload.node.attribute("class") ?? "") + " " + (runtime.stringValue(args[1]) ?? "")).trimmingCharacters(in: .whitespaces))
            return args[0]
        }
        element.method("removeClass", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return args[0] }
            let remove = runtime.stringValue(args[1]) ?? ""
            let classes = (payload.node.attribute("class") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0 != remove }
            payload.node.setAttribute("class", classes.joined(separator: " "))
            return args[0]
        }
        element.method("attr", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let name = runtime.stringValue(args[1]) ?? ""
            // jsoup resolves the `abs:` prefix against the document base URI.
            if name.hasPrefix("abs:") {
                let attribute = String(name.dropFirst(4))
                guard let raw = payload.node.attribute(attribute) else { return runtime.newString("") }
                return runtime.newString(JsoupHTML.absoluteUrl(raw, base: payload.document.baseUri))
            }
            return runtime.newString(payload.node.attribute(name) ?? "")
        }
        element.method("attr", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            if let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) {
                payload.node.setAttribute(runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? "")
            }
            return args[0]
        }
        element.method("hasAttr", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .boolean(false) }
            return .boolean(payload.node.attribute(runtime.stringValue(args[1]) ?? "") != nil)
        }
        element.method("removeAttr", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            if let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) {
                payload.node.removeAttribute(runtime.stringValue(args[1]) ?? "")
            }
            return args[0]
        }
        element.method("absUrl", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let raw = payload.node.attribute(runtime.stringValue(args[1]) ?? "") else { return runtime.newString("") }
            return runtime.newString(JsoupHTML.absoluteUrl(raw, base: payload.document.baseUri))
        }
        element.method("text", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.textContent())
        }
        element.method("ownText", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.textContent(ownOnly: true).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        element.method("wholeText", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.textContent())
        }
        element.method("hasText", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: JElementPayload.self)?.node.hasTextContent ?? false)
        }
        element.method("data", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            var output = ""
            for child in payload.node.children where child.kind == .data || child.kind == .text { output += child.text }
            return runtime.newString(output)
        }
        element.method("html", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.innerHTML())
        }
        element.method("html", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return args[0] }
            let parsed = JsoupHTML.parse(runtime.stringValue(args[1]) ?? "", baseUri: payload.document.baseUri)
            if let body = parsed.root.descendants().first(where: { $0.tag == "body" }) {
                payload.node.children.removeAll()
                for child in body.children {
                    child.parent = payload.node
                    payload.node.children.append(child)
                }
            }
            return args[0]
        }
        element.method("tagName", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            if let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
               let tag = runtime.stringValue(args[1]) {
                payload.node.tag = tag.lowercased()
            }
            return args[0]
        }
        element.method("appendChild", "(Lorg/jsoup/nodes/Node;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            if let parent: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
               let child: JElementPayload = runtime.payload(args[1], as: JElementPayload.self) {
                child.node.parent = parent.node
                parent.node.children.append(child.node)
            }
            return args[0]
        }
        element.method("prependChild", "(Lorg/jsoup/nodes/Node;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            if let parent: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
               let child: JElementPayload = runtime.payload(args[1], as: JElementPayload.self) {
                child.node.parent = parent.node
                parent.node.children.insert(child.node, at: 0)
            }
            return args[0]
        }
        element.method("tag", "()Lorg/jsoup/parser/Tag;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.makeNative("Lorg/jsoup/parser/Tag;", payload: payload.node.tag)
        }
        element.method("val", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            if payload.node.tag == "textarea" { return runtime.newString(payload.node.textContent()) }
            return runtime.newString(payload.node.attribute("value") ?? "")
        }
        element.method("children", "()Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: payload.node.elementChildren, document: payload.document))
        }
        element.method("childrenSize", "()I") { runtime, args, _ in
            let payload: JElementPayload? = runtime.payload(args[0], as: JElementPayload.self)
            return .int32(Int32(payload?.node.elementChildren.count ?? 0))
        }
        element.method("child", "(I)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let children = payload.node.elementChildren
            let index = Int(args[1].asInt32)
            guard index >= 0, index < children.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: children[index], document: payload.document))
        }
        element.method("firstElementChild", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let child = payload.node.elementChildren.first else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: child, document: payload.document))
        }
        element.method("lastElementChild", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let child = payload.node.elementChildren.last else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: child, document: payload.document))
        }
        element.method("nextElementSibling", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let sibling = JsoupSelector.nextElement(payload.node) else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: sibling, document: payload.document))
        }
        element.method("previousElementSibling", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self),
                  let sibling = JsoupSelector.previousElementPublic(payload.node) else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: sibling, document: payload.document))
        }
        element.method("siblings", "()Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let siblings = (payload.node.parent?.elementChildren ?? []).filter { $0 !== payload.node }
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: siblings, document: payload.document))
        }
        element.method("parents", "()Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            var parents: [JNode] = []
            var cursor = payload.node.parent
            while let node = cursor {
                if node.isElement { parents.append(node) }
                cursor = node.parent
            }
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: parents, document: payload.document))
        }
        element.method("select", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let nodes = try JsoupSelector.select(payload.node, selector: runtime.stringValue(args[1]) ?? "", runtime: runtime)
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: nodes, document: payload.document))
        }
        element.method("selectFirst", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            guard let node = try JsoupSelector.select(payload.node, selector: runtime.stringValue(args[1]) ?? "", runtime: runtime).first else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: node, document: payload.document))
        }
        element.method("is", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .boolean(false) }
            return .boolean(try JsoupSelector.matches(payload.node, selector: runtime.stringValue(args[1]) ?? "", runtime: runtime))
        }
        element.method("getElementById", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let id = runtime.stringValue(args[1]) ?? ""
            guard let node = payload.node.descendants().first(where: { $0.attribute("id") == id }) else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: node, document: payload.document))
        }
        element.method("getElementsByTag", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let tag = (runtime.stringValue(args[1]) ?? "").lowercased()
            let nodes = payload.node.descendants().filter { $0.tag == tag }
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: nodes, document: payload.document))
        }
        element.method("getElementsByClass", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let className = runtime.stringValue(args[1]) ?? ""
            let nodes = payload.node.descendants().filter { node in
                (node.attribute("class") ?? "").split(whereSeparator: { $0.isWhitespace }).contains(Substring(className))
            }
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: nodes, document: payload.document))
        }
        element.method("getElementsByAttribute", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let name = runtime.stringValue(args[1]) ?? ""
            let nodes = payload.node.descendants().filter { $0.attribute(name) != nil }
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: nodes, document: payload.document))
        }
        element.method("append", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return args[0] }
            let parsed = JsoupHTML.parse(runtime.stringValue(args[1]) ?? "", baseUri: payload.document.baseUri)
            if let body = parsed.root.descendants().first(where: { $0.tag == "body" }) {
                for child in body.children {
                    child.parent = payload.node
                    payload.node.children.append(child)
                }
            }
            return args[0]
        }
        element.method("prepend", "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;") { runtime, args, _ in args[0] }
        element.method("empty", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            if let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) { payload.node.children.removeAll() }
            return args[0]
        }
        element.method("equals", "(Ljava/lang/Object;)Z") { _, args, _ in .boolean(args[0].bits == args[1].bits) }
        element.method("hashCode", "()I") { _, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            return .int32(Int32(bitPattern: UInt32(truncatingIfNeeded: UInt(bitPattern: pointer) >> 4)))
        }
    }

    private static func elementsClasses() -> [[NativeClass]] {
        let elements = NativeClass("Lorg/jsoup/select/Elements;", superclass: "Ljava/util/ArrayList;", interfaces: ["Ljava/util/List;"])
        elements.method("size", "()I") { runtime, args, _ in
            let payload: JElementsPayload? = runtime.payload(args[0], as: JElementsPayload.self)
            return .int32(Int32(payload?.nodes.count ?? 0))
        }
        elements.method("isEmpty", "()Z") { runtime, args, _ in
            let payload: JElementsPayload? = runtime.payload(args[0], as: JElementsPayload.self)
            return .boolean((payload?.nodes.count ?? 0) == 0)
        }
        let getElement: NativeBody = { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < payload.nodes.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;")
            }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: payload.nodes[index], document: payload.document))
        }
        elements.method("get", "(I)Lorg/jsoup/nodes/Element;", getElement)
        elements.method("get", "(I)Ljava/lang/Object;", getElement)
        elements.method("first", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self),
                  let node = payload.nodes.first else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: node, document: payload.document))
        }
        elements.method("last", "()Lorg/jsoup/nodes/Element;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self),
                  let node = payload.nodes.last else { return .null }
            return runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: node, document: payload.document))
        }
        elements.method("select", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .null }
            var nodes: [JNode] = []
            for root in payload.nodes { nodes.append(contentsOf: try JsoupSelector.select(root, selector: runtime.stringValue(args[1]) ?? "", runtime: runtime)) }
            return runtime.makeNative("Lorg/jsoup/select/Elements;", payload: JElementsPayload(nodes: nodes, document: payload.document))
        }
        elements.method("text", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .null }
            return runtime.newString(payload.nodes.map { $0.textContent() }.joined(separator: " "))
        }
        elements.method("attr", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .null }
            let name = runtime.stringValue(args[1]) ?? ""
            if name.hasPrefix("abs:") {
                let attribute = String(name.dropFirst(4))
                for node in payload.nodes {
                    if let raw = node.attribute(attribute) {
                        return runtime.newString(JsoupHTML.absoluteUrl(raw, base: payload.document.baseUri))
                    }
                }
                return runtime.newString("")
            }
            for node in payload.nodes {
                if let value = node.attribute(name) { return runtime.newString(value) }
            }
            return runtime.newString("")
        }
        elements.method("attr", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return args[0] }
            let name = runtime.stringValue(args[1]) ?? ""
            let value = runtime.stringValue(args[2]) ?? ""
            for node in payload.nodes { node.setAttribute(name, value) }
            return args[0]
        }
        elements.method("remove", "()V") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .zero }
            for node in payload.nodes {
                if let parent = node.parent, let index = parent.children.firstIndex(where: { $0 === node }) {
                    parent.children.remove(at: index)
                }
            }
            return .zero
        }
        elements.method("addClass", "(Ljava/lang/String;)Lorg/jsoup/select/Elements;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return args[0] }
            let name = runtime.stringValue(args[1]) ?? ""
            for node in payload.nodes {
                let classes = (node.attribute("class") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if !classes.contains(name) {
                    node.setAttribute("class", (classes + [name]).joined(separator: " "))
                }
            }
            return args[0]
        }
        elements.method("hasAttr", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .boolean(false) }
            let name = runtime.stringValue(args[1]) ?? ""
            return .boolean(payload.nodes.contains { $0.attribute(name) != nil })
        }
        elements.method("hasText", "()Z") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .boolean(false) }
            return .boolean(payload.nodes.contains { $0.hasTextContent })
        }
        elements.method("eachText", "()Ljava/util/List;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .null }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(payload.nodes.map { runtime.newString($0.textContent()) }))
        }
        elements.method("html", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self),
                  let first = payload.nodes.first else { return .null }
            return runtime.newString(first.innerHTML())
        }
        elements.method("outerHtml", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .null }
            return runtime.newString(payload.nodes.map { $0.outerHTML() }.joined(separator: "\n"))
        }
        elements.method("is", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .boolean(false) }
            let selector = runtime.stringValue(args[1]) ?? ""
            for node in payload.nodes {
                if try JsoupSelector.matches(node, selector: selector, runtime: runtime) { return .boolean(true) }
            }
            return .boolean(false)
        }
        elements.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .null }
            let array = runtime.newArray(component: "Ljava/lang/Object;", count: payload.nodes.count)
            for (index, node) in payload.nodes.enumerated() {
                let element = runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: node, document: payload.document))
                runtime.setArrayElement(array, index: index, value: element)
            }
            return array
        }
        elements.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            guard let payload: JElementsPayload = runtime.payload(args[0], as: JElementsPayload.self) else { return .null }
            let values = payload.nodes.map { node in
                runtime.makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: node, document: payload.document))
            }
            return runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(values))
        }

        let attributes = NativeClass("Lorg/jsoup/nodes/Attributes;", superclass: "Ljava/lang/Object;")
        attributes.method("get", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.attribute(runtime.stringValue(args[1]) ?? "") ?? "")
        }
        attributes.method("size", "()I") { runtime, args, _ in
            let payload: JElementPayload? = runtime.payload(args[0], as: JElementPayload.self)
            return .int32(Int32(payload?.node.attributes.count ?? 0))
        }
        attributes.method("html", "()Ljava/lang/String;") { _, _, _ in .null }
        return [[elements, attributes]]
    }

    private static func textNodeClasses() -> [[NativeClass]] {
        let text = NativeClass("Lorg/jsoup/nodes/TextNode;", superclass: "Lorg/jsoup/nodes/Node;")
        text.method("text", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: JElementPayload = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            return runtime.newString(payload.node.textContent())
        }
        return [[text]]
    }

    private static func attributesClasses() -> [[NativeClass]] {
        let cls = NativeClass("Lorg/jsoup/select/NodeTraversor;", superclass: "Ljava/lang/Object;")
        cls.method("traverse", "(Lorg/jsoup/select/NodeVisitor;Lorg/jsoup/nodes/Node;)V") { _, _, _ in .zero }
        return [[cls]]
    }

    private static func parseClasses() -> [[NativeClass]] {
        let tag = NativeClass("Lorg/jsoup/parser/Tag;", superclass: "Ljava/lang/Object;")
        tag.staticMethod("valueOf", "(Ljava/lang/String;)Lorg/jsoup/parser/Tag;") { runtime, args, _ in
            runtime.makeNative("Lorg/jsoup/parser/Tag;", payload: (runtime.stringValue(args[0]) ?? "").lowercased())
        }
        tag.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: String.self) ?? "")
        }
        tag.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: String.self) ?? "")
        }
        let parser = NativeClass("Lorg/jsoup/parser/Parser;")
        parser.staticMethod("unescapeEntities", "(Ljava/lang/String;Z)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(JsoupHTML.decodeEntities(runtime.stringValue(args[0]) ?? ""))
        }
        parser.staticMethod("parse", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            let document = JsoupHTML.parse(runtime.stringValue(args[0]) ?? "", baseUri: runtime.stringValue(args[1]) ?? "")
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        let jsoup = NativeClass("Lorg/jsoup/Jsoup;")
        jsoup.staticMethod("parse", "(Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            let html = runtime.stringValue(args[0]) ?? ""
            let document = JsoupHTML.parse(html, baseUri: "")
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        jsoup.staticMethod("parse", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            let html = runtime.stringValue(args[0]) ?? ""
            let baseUri = runtime.stringValue(args[1]) ?? ""
            let document = JsoupHTML.parse(html, baseUri: baseUri)
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        jsoup.staticMethod("parse", "(Ljava/io/InputStream;Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            let data: Data = runtime.payload(args[0], as: Data.self) ?? Data()
            let charset = runtime.stringValue(args[1]) ?? "UTF-8"
            let html = runtime.decode(bytes: Array(data), charset: charset)
            let document = JsoupHTML.parse(html, baseUri: runtime.stringValue(args[2]) ?? "")
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        jsoup.staticMethod("parseBodyFragment", "(Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            let document = JsoupHTML.parseBodyFragment(runtime.stringValue(args[0]) ?? "", baseUri: "")
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        jsoup.staticMethod("parseBodyFragment", "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            let document = JsoupHTML.parseBodyFragment(runtime.stringValue(args[0]) ?? "", baseUri: runtime.stringValue(args[1]) ?? "")
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        jsoup.staticMethod("unescapeEntities", "(Ljava/lang/String;Z)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(JsoupHTML.decodeEntities(runtime.stringValue(args[0]) ?? ""))
        }
        return [[tag], [parser], [jsoup]]
    }

    static func string(_ runtime: VMRuntime, _ value: VMValue, _ keyPath: KeyPath<JNode, String>) -> VMValue {
        guard let payload: JElementPayload = runtime.payload(value, as: JElementPayload.self) else { return .null }
        return runtime.newString(payload.node[keyPath: keyPath])
    }
}

extension JsoupSelector {
    static func previousElementPublic(_ node: JNode) -> JNode? { previousElement(node) }
}
