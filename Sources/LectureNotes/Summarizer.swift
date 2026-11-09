import Foundation

struct LLMConfig {
    var provider: LLMProvider
    var model: String
    var baseURL: String
    var apiKey: String
    var stylePrompt: String
}

private func firstSentence(of text: String) -> String {
    guard let end = text.range(of: ". ") else { return text }
    return String(text[..<end.lowerBound]) + "."
}

enum SummarizerError: LocalizedError {
    case missingKey, badURL, http(Int, String), refusal, emptyResponse, offline, unreachable, timedOut

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your AI key in Settings → AI, then hit Retry."
        case .badURL: "The model base URL in settings is invalid."
        case .http(let code, let message):
            switch code {
            case 401, 403: "The AI key was rejected. Check it in Settings → AI."
            case 429: "Free AI quota hit. Wait a minute, then Retry."
            case 500, 502, 503, 504, 529: "The AI service is overloaded right now. Your transcript is saved, so Retry in a minute."
            case 400 where message.localizedCaseInsensitiveContains("api key"): "The AI key was rejected. Check it in Settings → AI."
            case 404: "The AI model in Settings → AI isn't available anymore. Pick another model there."
            default: "AI error \(code): \(firstSentence(of: message))"
            }
        case .refusal: "The model declined to summarize this transcript."
        case .emptyResponse: "The model returned no notes."
        case .offline: "You're offline. Your recording and transcript are saved, so hit Retry once you're connected."
        case .unreachable: "Couldn't reach the AI server. If you use Ollama, make sure it's running. Your transcript is saved, so hit Retry."
        case .timedOut: "The AI took too long to answer. Hit Retry, or pick a faster model in Settings → AI."
        }
    }
}

struct LectureSummary {
    var notes: String
    /// Short AI-picked name, e.g. "Mass Spectrometry Fragmentation".
    var name: String?
    /// Exams, deadlines, and things flagged as tested, with real dates.
    var important: [String]
}

enum Summarizer {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 360
        return URLSession(configuration: config)
    }()

    static func summarize(_ transcript: String, context: String = "", slides: String = "", date: Date = Date(), config: LLMConfig) async throws -> LectureSummary {
        if config.provider.needsKey && config.apiKey.isEmpty { throw SummarizerError.missingKey }
        let day = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let system = config.stylePrompt + """


        Respond with only the Markdown notes. Write math as plain text with Unicode symbols (Θ(log n), n², ≤, ∑), never LaTeX or $...$, because the notes get pasted into apps that don't render it.

        After the notes, add this block, filled in:
        <lecture-info>
        name: a short name for the lecture, 2–6 words, no date or course number
        important:
        - one line per exam, quiz, homework, deadline, or thing the lecturer said will be tested or is important to know
        </lecture-info>
        The lecture was on \(day). Write dates in the important lines as real dates like "Fri, Nov 13" (turn "next Friday" into the date). Leave the important list empty if nothing like that came up; don't pad it.
        """
        var user = ""
        if !context.isEmpty {
            user += "Context from the student (topic, key terms, things to focus on). Speech recognition often mangles these terms, so use this to correct them:\n<context>\n\(context)\n</context>\n\n"
        }
        if !slides.isEmpty {
            user += "The lecture's slides. Use them to spell terms, names, and formulas correctly, fill in what the speaker referred to (\"this diagram\", \"as you can see\"), and follow the lecture's structure. The notes are about what was said, so don't copy slides that weren't covered:\n<slides>\n\(Slides.forPrompt(slides))\n</slides>\n\n"
        }
        user += "Lecture transcript:\n<transcript>\n\(transcript)\n</transcript>"

        let raw: String
        do {
            raw = config.provider == .anthropic
                ? try await anthropic(system: system, user: user, config: config)
                : try await openAICompatibleWithFallback(system: system, user: user, config: config)
        } catch let error as URLError where error.code == .timedOut {
            throw SummarizerError.timedOut
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw SummarizerError.unreachable
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed].contains(error.code) {
            throw SummarizerError.offline
        }
        let summary = parse(raw)
        guard !summary.notes.isEmpty else { throw SummarizerError.emptyResponse }
        return summary
    }

    /// Splits the notes from the trailing <lecture-info> block. Models that skip the block still give usable notes.
    static func parse(_ raw: String) -> LectureSummary {
        guard let start = raw.range(of: "<lecture-info>") else {
            return LectureSummary(notes: stripFence(raw), name: nil, important: [])
        }
        let after = raw[start.upperBound...]
        let end = after.range(of: "</lecture-info>")
        let info = end.map { after[..<$0.lowerBound] } ?? after
        let rest = end.map { String(after[$0.upperBound...]) } ?? ""
        var name: String?
        var important: [String] = []
        for line in info.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.lowercased().hasPrefix("name:") {
                let value = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " *\"'"))
                if !value.isEmpty { name = String(value.prefix(80)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty && !["none", "n/a", "nothing"].contains(item.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                    important.append(item)
                }
            }
        }
        let notes = stripFence(String(raw[..<start.lowerBound]) + rest)
        return LectureSummary(notes: notes, name: name, important: important)
    }

    private static func anthropic(system: String, user: String, config: LLMConfig) async throws -> String {
        guard let url = URL(string: config.baseURL.trimmingSlash + "/v1/messages"), url.host != nil else { throw SummarizerError.badURL }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 16_000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": "medium"],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if supportsFallbacks(config.model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        if json["stop_reason"] as? String == "refusal" { throw SummarizerError.refusal }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return json["stop_reason"] as? String == "max_tokens" ? stripFence(text) + cutOffNote : text
    }

    private static func supportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable-5") || model == "claude-sonnet-5-5"
    }

    /// If the Gemini model is retired or still overloaded after retries, ask Google which Flash models
    /// this key can use and try those, so a model being retired never breaks the app.
    private static func openAICompatibleWithFallback(system: String, user: String, config: LLMConfig) async throws -> String {
        do {
            return try await openAICompatible(system: system, user: user, config: config)
        } catch SummarizerError.http(let code, let message)
            where config.provider == .gemini && shouldFallBack(code: code, message: message) {
            var lastError: Error = SummarizerError.http(code, message)
            for model in await geminiFallbacks(config: config).prefix(3) {
                var fallback = config
                fallback.model = model
                do {
                    return try await openAICompatible(system: system, user: user, config: fallback)
                } catch SummarizerError.http(let code, let message) where shouldFallBack(code: code, message: message) {
                    lastError = SummarizerError.http(code, message)
                }
            }
            throw lastError
        }
    }

    private static func shouldFallBack(code: Int, message: String) -> Bool {
        [404, 500, 503].contains(code) || (code == 400 && ["not found", "no longer available", "not supported"].contains { message.localizedCaseInsensitiveContains($0) })
    }

    /// Newest stable text Flash models from the key's model list, then the Flash-Lite alias as a last resort.
    static func geminiFallbacks(config: LLMConfig) async -> [String] {
        var models: [String] = []
        if let url = URL(string: config.baseURL.trimmingSlash + "/models") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["data"] as? [[String: Any]] {
                models = list.compactMap { $0["id"] as? String }
                    .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
                    .filter(isTextFlashModel)
                    .sorted { version(of: $1).lexicographicallyPrecedes(version(of: $0)) }
            }
        }
        models.append("gemini-flash-lite-latest")
        var seen: Set<String> = [config.model]
        return models.filter { seen.insert($0).inserted }
    }

    private static func isTextFlashModel(_ id: String) -> Bool {
        let banned = ["lite", "image", "tts", "audio", "live", "embedding", "preview", "exp", "thinking", "8b", "latest"]
        return id.hasPrefix("gemini-") && id.contains("flash") && !banned.contains { id.contains($0) }
    }

    /// "gemini-3.8-flash" → [3, 8], so newer versions sort first.
    private static func version(of id: String) -> [Int] {
        let part = id.dropFirst("gemini-".count).prefix { $0.isNumber || $0 == "." }
        return part.split(separator: ".").compactMap { Int($0) }
    }

    private static func openAICompatible(system: String, user: String, config: LLMConfig) async throws -> String {
        guard let url = URL(string: config.baseURL.trimmingSlash + "/chat/completions"), url.host != nil else { throw SummarizerError.badURL }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        let choices = json["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""
        return choices.first?["finish_reason"] as? String == "length" ? stripFence(text) + cutOffNote : text
    }

    /// Retries overloads, rate limits, and dropped connections with backoff before giving up.
    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let delays: [Duration] = [.seconds(3), .seconds(8), .seconds(20)]
        for delay in delays {
            do {
                return try await sendOnce(request)
            } catch let error where isTransient(error) {
                try await Task.sleep(for: delay)
            }
        }
        return try await sendOnce(request)
    }

    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case SummarizerError.http(let code, _): [408, 429, 500, 502, 503, 504, 529].contains(code)
        case let error as URLError: [.networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
        default: false
        }
    }

    private static func sendOnce(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SummarizerError.http(status, errorMessage(from: data))
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Pulls `error.message` out of OpenAI/Anthropic/Gemini error bodies (Gemini wraps it in an array).
    private static func errorMessage(from data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        if let error = object?["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<") { return "No details from the provider." }
        return String(text.prefix(300))
    }

    private static let cutOffNote = "\n\n---\n\n*Notes were cut off because the model hit its output limit. Try a model with a bigger limit in Settings → AI.*"

    static func stripFence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    var trimmingSlash: String {
        var s = trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
