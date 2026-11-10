import Foundation

enum AudioSource: String, CaseIterable, Identifiable {
    case mic, micAndSystem
    var id: String { rawValue }
    var label: String { self == .mic ? "Mic only" : "Mic + system audio" }
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case gemini, anthropic, openai, openrouter, deepseek, ollama, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Claude (Anthropic)"
        case .openai: "OpenAI"
        case .gemini: "Gemini (free)"
        case .openrouter: "OpenRouter (has free models)"
        case .deepseek: "DeepSeek"
        case .ollama: "Ollama (local, free)"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com"
        case .openai: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-5-mini"
        case .gemini: "gemini-flash-latest"
        case .openrouter: "deepseek/deepseek-chat-v3.1:free"
        case .deepseek: "deepseek-chat"
        case .ollama: "qwen3:8b"
        case .custom: ""
        }
    }

    /// Key is required (custom endpoints may or may not need one, so it's optional there).
    var needsKey: Bool { self != .ollama && self != .custom }
    var showsKeyField: Bool { self != .ollama }

    /// "claude-opus-5-5" → "Claude Opus 5.5", "gemini-flash-latest" → "Gemini Flash".
    static func displayName(for model: String) -> String {
        let name = model.components(separatedBy: "/").last ?? model
        var words: [String] = []
        for part in name.components(separatedBy: CharacterSet(charactersIn: "-_ ")) where !part.isEmpty && part != "latest" {
            if let last = words.last, last.last?.isNumber == true, part.allSatisfy(\.isNumber) {
                words[words.count - 1] = last + "." + part
            } else if ["gpt", "oss"].contains(part.lowercased()) {
                words.append(part.uppercased())
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return words.isEmpty ? model : words.joined(separator: " ")
    }

    /// Where to get a key, if the provider has a sign-up page.
    var keyURL: URL? {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
        case .ollama, .custom: nil
        }
    }

    /// Model names we used to ship as defaults; upgraded to the current default on load.
    var legacyDefaults: Set<String> {
        self == .gemini ? ["gemini-2.5-flash"] : []
    }
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    static let defaultStylePrompt = """
    You turn raw lecture transcripts into concise study notes in Markdown. Every fact appears exactly once.

    - Start with a single `# ` heading: a short, specific title for the lecture.
    - Then a short overview paragraph (2–4 sentences) giving the big picture: what the lecture was about, how its topics connect, and the main takeaway. Keep it high-level; leave specific facts, numbers, and definitions to the sections.
    - Organize the rest by topic with `## ` headings, in the order they were covered.
    - Under each topic, go straight to bullet points. Nest sub-bullets for details, steps, and examples.
    - Define each term once, where it first comes up, and **bold** it there. Use *italics* sparingly, for emphasis or examples.
    - Keep formulas, numbers, dates, names, and examples the lecturer gave. Call out anything flagged as important or on the exam.

    Be terse: short phrases and fragments are fine, and a bullet shouldn't repeat its parent or a sibling in other words. Skip filler ("it is important to note", "this allows"), restatements, and recaps. Don't add a glossary or summary at the end. Don't mention that this came from a transcript. The transcript is from speech recognition, so quietly fix obvious mis-heard technical terms.
    """

    private static let legacyStylePrompt = """
    You turn raw lecture transcripts into clean, minimal study notes in Markdown.

    - Start with a single `# ` heading: a short, specific title for the lecture.
    - Then a 2–3 sentence summary paragraph.
    - Organize the rest by topic with `## ` headings, in the order they were covered.
    - Under each topic: one plain statement capturing the main idea, then bullet points with the supporting details. Nest sub-bullets when it helps.
    - **Bold** key terms and important concepts. Use *italics* for definitions, emphasis, and examples.
    - Keep formulas, dates, names, and examples the lecturer gave. Call out anything flagged as important or on the exam.
    - End with `## Key Terms` (term — short definition).

    No filler. Don't mention that this came from a transcript. The transcript is from speech recognition, so quietly fix obvious mis-heard technical terms.
    """

    @Published var audioSource: AudioSource { didSet { d.set(audioSource.rawValue, forKey: "audioSource") } }
    @Published var localeID: String {
        didSet {
            d.set(localeID, forKey: "localeID")
            let id = localeID
            Task { await LiveTranscriber.preload(localeID: id) }
        }
    }
    @Published var stylePrompt: String { didSet { d.set(stylePrompt, forKey: "stylePrompt") } }
    /// Re-transcribe with Whisper after Stop (needs the model downloaded).
    @Published var highAccuracy: Bool { didSet { d.set(highAccuracy, forKey: "highAccuracy") } }
    @Published var openDocWhenDone: Bool { didSet { d.set(openDocWhenDone, forKey: "openDocWhenDone") } }
    @Published var folderID: String { didSet { d.set(folderID, forKey: "folderID") } }
    @Published var folderName: String { didSet { d.set(folderName, forKey: "folderName") } }

    @Published var provider: LLMProvider {
        didSet {
            d.set(provider.rawValue, forKey: "provider")
            loadProviderFields()
        }
    }
    // `loading` stops didSet from writing back while we read a provider's saved values.
    // Without it, a failed Keychain read (e.g. access denied) would wipe the stored key.
    private var loading = false
    @Published var model = "" { didSet { if !loading { d.set(model, forKey: "model.\(provider.rawValue)") } } }
    @Published var baseURL = "" { didSet { if !loading { d.set(baseURL, forKey: "baseURL.\(provider.rawValue)") } } }
    @Published var apiKey = "" {
        didSet { if !loading { Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "apiKey.\(provider.rawValue)") } }
    }

    private init() {
        audioSource = AudioSource(rawValue: d.string(forKey: "audioSource") ?? "") ?? .mic
        localeID = d.string(forKey: "localeID") ?? Locale.current.identifier
        let savedPrompt = d.string(forKey: "stylePrompt")
        stylePrompt = savedPrompt == nil || savedPrompt == Self.legacyStylePrompt ? Self.defaultStylePrompt : savedPrompt!
        openDocWhenDone = d.object(forKey: "openDocWhenDone") as? Bool ?? true
        highAccuracy = d.object(forKey: "highAccuracy") as? Bool ?? true
        folderID = d.string(forKey: "folderID") ?? ""
        folderName = d.string(forKey: "folderName") ?? "Lecture Notes"
        provider = LLMProvider(rawValue: d.string(forKey: "provider") ?? "") ?? .gemini
        loadProviderFields()
    }

    private func loadProviderFields() {
        loading = true
        defer { loading = false }
        let savedModel = d.string(forKey: "model.\(provider.rawValue)")
        model = savedModel.flatMap { provider.legacyDefaults.contains($0) ? nil : $0 } ?? provider.defaultModel
        baseURL = d.string(forKey: "baseURL.\(provider.rawValue)") ?? provider.defaultBaseURL
        apiKey = Keychain.get("apiKey.\(provider.rawValue)") ?? ""
    }
}
