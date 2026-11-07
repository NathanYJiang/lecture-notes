import AVFoundation
import Speech

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String), empty

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): "On-device transcription doesn't support “\(id)”. Change the language in settings."
        case .empty: "No speech was detected in the recording."
        }
    }
}

enum Transcriber {
    static func transcribe(_ url: URL, localeID: String, terms: [String] = []) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw TranscriberError.unsupportedLocale(localeID)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        let collector = Task {
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            }
            return parts.joined(separator: " ")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try? await analyzer.setContext(LiveTranscriber.context(for: terms))
        let file = try AVAudioFile(forReading: url)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let transcript = try await collector.value
        guard !transcript.isEmpty else { throw TranscriberError.empty }
        return transcript
    }
}
