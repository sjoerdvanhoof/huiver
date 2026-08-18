import Foundation

/// A whole XML document as a tree, because the alternative is three delegates.
///
/// EPUB parsing needs to walk a package document, a table of contents in either
/// of two formats, and sometimes a nav document — all small files, all read
/// once. Loading each into a tree and querying it is far less code than an
/// `XMLParser` delegate per format, and `XMLDocument` does not exist on iOS.
public final class XMLTree {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [XMLTree] = []
    public private(set) var text: String = ""

    init(name: String, attributes: [String: String]) {
        // Namespace prefixes vary between producers (`opf:item`, `item`,
        // `dc:title`), and none of them disambiguate anything we look for.
        self.name = name.contains(":") ? String(name.split(separator: ":").last!) : name
        self.attributes = Dictionary(
            attributes.map { key, value in
                (key.contains(":") ? String(key.split(separator: ":").last!) : key, value)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public static func parse(_ data: Data) -> XMLTree? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        // A truncated document still yields whatever was read before the fault,
        // which for a table of contents is usually enough to be useful.
        parser.parse()
        return builder.root
    }

    /// Every descendant with this tag name, in document order.
    public func all(_ name: String) -> [XMLTree] {
        var out: [XMLTree] = []
        if self.name == name { out.append(self) }
        for child in children { out += child.all(name) }
        return out
    }

    public func first(_ name: String) -> XMLTree? { all(name).first }

    public subscript(attribute: String) -> String? { attributes[attribute] }

    /// All text in this element and everything under it.
    public var allText: String {
        children.reduce(text) { $0 + $1.allText }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        private var stack: [XMLTree] = []

        func parser(
            _ parser: XMLParser,
            didStartElement element: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let node = XMLTree(name: element, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement element: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}
