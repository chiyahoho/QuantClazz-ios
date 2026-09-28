import Foundation
import Markdown

/// Converts the official site's Vditor Markdown source to inert HTML.
/// Raw HTML is displayed as text; resource URLs are restricted by scheme.
enum MarkdownHTML {
    static func render(_ source: String) -> String {
        var renderer = Renderer()
        return renderer.node(Document(parsing: source))
    }
    static func imageURLs(_ source: String) -> [URL] {
        func collect(_ markup: any Markup) -> [URL] {
            var urls: [URL] = []
            if let image = markup as? Image, let raw = image.source, let url = URL(string: raw, relativeTo: ForumClient.siteURL)?.absoluteURL, url.scheme?.lowercased() == "https", url.host != nil { urls.append(url) }
            return urls + markup.children.flatMap(collect)
        }
        var seen = Set<URL>()
        return collect(Document(parsing: source)).filter { seen.insert($0).inserted }
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func resource(_ value: String?, image: Bool = false) -> String? {
        guard let value, let url = URL(string: value, relativeTo: ForumClient.siteURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), image ? scheme == "https" : ["http", "https"].contains(scheme) else { return nil }
        return escape(url.absoluteString)
    }
    private struct Renderer {
        private var hiddenTags: [String] = []

        mutating func node(_ markup: any Markup) -> String {
            // Raw HTML must still be visited while hidden so its closing tag can
            // end suppression. Code nodes never reach this parser.
            if let html = markup as? HTMLBlock {
                let visible = processRawHTML(html.rawHTML)
                return visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "<pre>" + visible + "</pre>"
            }
            if let html = markup as? InlineHTML { return processRawHTML(html.rawHTML) }

            let wasHidden = !hiddenTags.isEmpty
            if wasHidden, markup is Text || markup is InlineCode || markup is CodeBlock { return "" }
            let children = markup.children.map { node($0) }.joined()
            if wasHidden && children.isEmpty { return "" }
            switch markup {
        case let text as Text: return escape(text.string)
        case is Document: return children
        case is Paragraph: return children.isEmpty ? "" : "<p>" + children + "</p>"
        case let heading as Heading: return "<h\(heading.level)>" + children + "</h\(heading.level)>"
        case is Strong: return "<strong>" + children + "</strong>"
        case is Emphasis: return "<em>" + children + "</em>"
        case is Strikethrough: return "<del>" + children + "</del>"
        case is BlockQuote: return "<blockquote>" + children + "</blockquote>"
        case is UnorderedList: return "<ul>" + children + "</ul>"
        case let list as OrderedList: return "<ol start=\"\(list.startIndex)\">" + children + "</ol>"
        case is ListItem: return "<li>" + children + "</li>"
        case let code as InlineCode: return "<code>" + escape(code.code) + "</code>"
        case let code as CodeBlock: return "<pre><code>" + escape(code.code) + "</code></pre>"
        case is SoftBreak: return "\n"
        case is LineBreak: return "<br>"
        case is ThematicBreak: return "<hr>"
        case let link as Link:
            guard let url = resource(link.destination) else { return children }
            return "<a href=\"" + url + "\">" + children + "</a>"
        case let image as Image:
            guard let url = resource(image.source, image: true) else { return children }
            var preview = URLComponents()
            preview.scheme = "qc-image"; preview.host = "open"
            preview.queryItems = [URLQueryItem(name: "url", value: image.source.flatMap { URL(string: $0, relativeTo: ForumClient.siteURL)?.absoluteURL.absoluteString })]
            let link = escape(preview.url!.absoluteString)
            return "<a href=\"" + link + "\"><img src=\"" + url + "\" alt=\"" + escape(image.plainText) + "\"></a>"
        case is Table: return "<table>" + children + "</table>"
        case is Table.Head: return "<thead><tr>" + children + "</tr></thead>"
        case is Table.Body: return "<tbody>" + children + "</tbody>"
        case is Table.Row: return "<tr>" + children + "</tr>"
        case is Table.Cell:
            let tag = markup.parent is Table.Head ? "th" : "td"
            return "<" + tag + ">" + children + "</" + tag + ">"
            default: return children
            }
        }

        private mutating func processRawHTML(_ raw: String) -> String {
            var output = ""
            var cursor = raw.startIndex
            while cursor < raw.endIndex {
                guard let open = raw[cursor...].firstIndex(of: "<") else {
                    if hiddenTags.isEmpty { output += escape(String(raw[cursor...])) }
                    break
                }
                if hiddenTags.isEmpty { output += escape(String(raw[cursor..<open])) }
                guard let end = tagEnd(in: raw, from: open) else {
                    if hiddenTags.isEmpty { output += escape(String(raw[open...])) }
                    break
                }
                let token = String(raw[open...end])
                let wasHidden = !hiddenTags.isEmpty
                let startsHidden = updateHiddenState(for: token)
                if !wasHidden && !startsHidden { output += escape(token) }
                cursor = raw.index(after: end)
            }
            return output
        }

        private func tagEnd(in text: String, from start: String.Index) -> String.Index? {
            var index = text.index(after: start)
            var quote: Character?
            while index < text.endIndex {
                let character = text[index]
                if let active = quote {
                    if character == active { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    return index
                }
                index = text.index(after: index)
            }
            return nil
        }

        private mutating func updateHiddenState(for token: String) -> Bool {
            guard let match = token.range(of: #"^<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)"#, options: .regularExpression) else { return false }
            let prefix = token[match]
            let closing = prefix.contains("/")
            let name = prefix
                .replacingOccurrences(of: #"^<\s*/?\s*"#, with: "", options: .regularExpression)
                .lowercased()
            if closing {
                if let index = hiddenTags.lastIndex(of: name) { hiddenTags.removeSubrange(index...) }
                return false
            }
            let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
            let selfClosing = token.range(of: #"/\s*>$"#, options: .regularExpression) != nil || voidTags.contains(name)
            if hiddenTags.isEmpty {
                guard hasDisplayNoneStyle(token) else { return false }
                if !selfClosing { hiddenTags.append(name) }
            } else if !selfClosing {
                hiddenTags.append(name)
            }
            return hiddenTags.isEmpty ? hasDisplayNoneStyle(token) : true
        }

        private func hasDisplayNoneStyle(_ tag: String) -> Bool {
            guard let styleMatch = tag.range(
                of: #"(?i)(?:\s|^)style\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
                options: .regularExpression
            ) else { return false }
            let attribute = String(tag[styleMatch])
            guard let equals = attribute.firstIndex(of: "=") else { return false }
            var value = attribute[attribute.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = value.first, (first == "\"" || first == "'"), value.last == first {
                value.removeFirst(); value.removeLast()
            }
            return value.range(
                of: #"(?i)(?:^|;)\s*display\s*:\s*none\s*(?:!\s*important\s*)?(?:;|$)"#,
                options: .regularExpression
            ) != nil
        }
    }
}
