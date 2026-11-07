import Foundation

/// Minimal Markdown → HTML for Google Docs import: headings, nested lists,
/// paragraphs, pipe tables, rules, quotes, bold/italic/code.
enum Markdown {
    static func title(of markdown: String) -> String? {
        markdown.components(separatedBy: "\n")
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
    }

    /// `styled` adds CSS for viewing in a browser; leave it off for Google Docs import/paste.
    static func html(_ markdown: String, title: String? = nil, styled: Bool = false) -> String {
        var out = ""
        var lists: [(indent: Int, tag: String)] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func closeLists(above indent: Int = -1) {
            while let last = lists.last, last.indent > indent {
                out += "</\(last.tag)>\n"
                lists.removeLast()
            }
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"
            paragraph = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            out += "<table border=\"1\" style=\"border-collapse:collapse\">\n"
            for (i, row) in table.enumerated() {
                let tag = i == 0 ? "th" : "td"
                out += "<tr>" + row.map { "<\(tag) style=\"vertical-align:top;padding:6px\">\(inline($0))</\(tag)>" }.joined() + "</tr>\n"
            }
            out += "</table>\n"
            table = []
        }
        func flushCode() {
            guard let lines = code else { return }
            out += "<pre><code>\(escape(lines.joined(separator: "\n")))</code></pre>\n"
            code = nil
        }
        func flushAll() {
            flushParagraph()
            flushTable()
            closeLists()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count

            if trimmed.hasPrefix("```") {
                if code != nil {
                    flushCode()
                } else {
                    flushAll()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushTable()
                continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph()
                closeLists()
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
                if !isSeparator { table.append(cells) }
                continue
            }
            flushTable()

            if let level = headingLevel(trimmed) {
                flushAll()
                let text = trimmed.dropFirst(level + 1)
                out += "<h\(level)>\(inline(String(text)))</h\(level)>\n"
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushAll()
                out += "<hr>\n"
                continue
            }

            if let (tag, content) = listItem(trimmed) {
                flushParagraph()
                closeLists(above: indent)
                if let last = lists.last, last.indent == indent, last.tag != tag {
                    out += "</\(last.tag)>\n"
                    lists.removeLast()
                }
                if lists.last.map({ $0.indent < indent }) ?? true {
                    out += "<\(tag)>\n"
                    lists.append((indent, tag))
                }
                out += "<li>\(inline(content))</li>\n"
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushAll()
                out += "<blockquote>\(inline(String(trimmed.dropFirst(2))))</blockquote>\n"
                continue
            }

            closeLists()
            paragraph.append(trimmed)
        }
        flushCode()
        flushAll()

        let titleTag = title.map { "<title>\(inline($0))</title>" } ?? ""
        guard styled else { return "<html><head><meta charset=\"utf-8\">\(titleTag)</head><body>\n\(out)</body></html>" }
        return "<html><head><meta charset=\"utf-8\">\(titleTag)<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:760px;margin:40px auto;padding:0 20px;line-height:1.55;color:#1d1d1f}h1{font-size:26px}h2{font-size:19px;margin-top:28px}li{margin:3px 0}code{background:#f2f2f5;padding:1px 4px;border-radius:4px}pre{background:#f2f2f5;padding:12px;border-radius:8px;overflow-x:auto}pre code{padding:0}</style></head><body>\n\(out)</body></html>"
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("ol", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static let codeSpan = try! NSRegularExpression(pattern: #"`([^`]+)`"#)

    private static let inlineRules: [(NSRegularExpression, String)] = [
        (#"\*\*(.+?)\*\*"#, "<b>$1</b>"),
        (#"__(.+?)__"#, "<b>$1</b>"),
        (#"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\*)"#, "<i>$1</i>"),
        (#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, "<i>$1</i>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Code spans are cut out first so `__init__` or `a*b*c` inside backticks isn't turned into bold/italic.
    static func inline(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in codeSpan.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += formatted(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            out += "<code>\(escape(ns.substring(with: match.range(at: 1))))</code>"
            last = match.range.location + match.range.length
        }
        return out + formatted(ns.substring(from: last))
    }

    private static func formatted(_ text: String) -> String {
        var s = escape(text)
        for (regex, template) in inlineRules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }
}
