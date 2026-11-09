import Foundation
import NaturalLanguage
import PDFKit

/// Lecture slides attached to a recording. Their text gives the AI context, and their jargon
/// becomes speech-recognition vocabulary so the transcriber can actually hear those words.
enum Slides {
    static let fileTypes = ["pdf", "pptx", "txt", "md"]
    static let maxPromptChars = 80_000
    static let maxTerms = 150

    static func text(from url: URL) throws -> String {
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw SlidesError.unreadable(url.lastPathComponent) }
            text = (0..<doc.pageCount).compactMap { index in
                let page = doc.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return page.isEmpty ? nil : "--- Slide \(index + 1) ---\n\(page)"
            }
            .joined(separator: "\n\n")
        case "pptx":
            text = try pptxText(url)
        default:
            text = try String(contentsOf: url, encoding: .utf8)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlidesError.noText(url.lastPathComponent)
        }
        return text
    }

    /// .pptx is a zip of XML files, one per slide; the visible text lives in <a:t> tags.
    private static func pptxText(_ url: URL) throws -> String {
        let list = try unzip(["-Z1", url.path])
        let slides = list.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }
        guard !slides.isEmpty else { throw SlidesError.unreadable(url.lastPathComponent) }
        let regex = #/<a:t>([^<]*)</a:t>/#
        return try slides.enumerated().map { index, path in
            let xml = try unzip(["-p", url.path, path])
            let runs = xml.matches(of: regex).map { decodeEntities(String($0.1)) }
            return "--- Slide \(index + 1) ---\n" + runs.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    private static func slideNumber(_ path: String) -> Int {
        Int(path.filter(\.isNumber)) ?? 0
    }

    private static func unzip(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Vocabulary for the recognizer: slide titles as phrases, then nouns and names ranked so jargon
    /// (capitalized names, acronyms, identifiers like "malloc" or "O(n)", long words) beats everyday words.
    static func terms(from text: String) -> [String] {
        var scores: [String: Int] = [:]
        var order: [String] = []
        var spelling: [String: String] = [:]
        func add(_ term: String, _ score: Int) {
            let key = term.lowercased()
            if scores[key] == nil {
                order.append(key)
                spelling[key] = term
            }
            scores[key, default: 0] += score
        }

        for slide in text.components(separatedBy: "--- Slide ").dropFirst() {
            let lines = slide.components(separatedBy: .newlines).dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let title = lines.first(where: { !$0.isEmpty }),
               title.count <= 50, (2...6).contains(title.split(separator: " ").count) {
                add(title, 6)
            }
        }

        let text = text.replacing(#/--- Slide \d+ ---/#, with: "")
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let keep: Set<NLTag> = [.noun, .otherWord, .adjective, .verb]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = String(text[range])
            // URLs, file names, and emails aren't spoken.
            guard !word.contains(where: { "/_@.".contains($0) }) else { return true }
            let letters = word.filter(\.isLetter)
            let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
            let isCamel = word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
            let mixesDigits = word.contains(where: \.isNumber) && !letters.isEmpty
            let special = isAcronym || isCamel || mixesDigits
            guard special || (tag.map(keep.contains) == true && letters.count >= 5) else { return true }
            var score = 1
            if special { score += 3 }
            if word.first?.isUppercase == true && !isAcronym { score += 2 }
            if letters.count >= 8 { score += 1 }
            if tag == .verb && !special { score -= 1 }
            if score > 0 { add(word, score) }
            return true
        }

        return order.enumerated()
            .sorted { (scores[$0.element]!, -$0.offset) > (scores[$1.element]!, -$1.offset) }
            .prefix(maxTerms)
            .compactMap { spelling[$0.element] }
    }

    static func forPrompt(_ text: String) -> String {
        text.count > maxPromptChars ? String(text.prefix(maxPromptChars)) + "\n[…slides truncated]" : text
    }
}

enum SlidesError: LocalizedError {
    case unreadable(String), noText(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name). Try exporting it as a PDF."
        case .noText(let name): "\(name) has no selectable text (it may be scanned images)."
        }
    }
}
