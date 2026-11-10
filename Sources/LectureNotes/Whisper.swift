import AVFoundation
import Foundation
import whisper

enum WhisperError: LocalizedError {
    case modelMissing, loadFailed, unreadableAudio, failed(Int32), empty

    var errorDescription: String? {
        switch self {
        case .modelMissing: "The high-accuracy speech model isn't downloaded."
        case .loadFailed: "Couldn't load the high-accuracy speech model. Try deleting and re-downloading it in Settings → Audio."
        case .unreadableAudio: "Couldn't read the recording's audio."
        case .failed(let code): "High-accuracy transcription failed (code \(code))."
        case .empty: "No speech was detected in the recording."
        }
    }
}

/// Files for whisper.cpp: the Large v3 Turbo speech model and the Silero voice-activity model.
/// Skipping silence with VAD is what keeps Whisper from looping on long lecture recordings.
enum WhisperFiles {
    struct File {
        let name: String
        let url: URL
        let size: Int64
    }

    static let model = File(name: "ggml-large-v3-turbo.bin",
                            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
                            size: 1_624_555_275)
    static let vad = File(name: "ggml-silero-v5.1.2.bin",
                          url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
                          size: 885_098)
    static let all = [vad, model]

    static let dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "LectureNotes/Models")

    static func path(_ file: File) -> URL { dir.appending(path: file.name) }

    static func isInstalled(_ file: File) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path(file).path)[.size] as? Int64) ?? nil
        return size == file.size
    }

    static var isInstalled: Bool { all.allSatisfy(isInstalled) }

    static var totalSize: Int64 { all.reduce(0) { $0 + $1.size } }
}

/// Downloads and manages the Whisper model files, with progress for the UI.
@MainActor
final class WhisperModel: ObservableObject {
    static let shared = WhisperModel()

    enum State: Equatable {
        case missing, downloading(Double), ready, failed(String)
    }

    @Published private(set) var state: State = WhisperFiles.isInstalled ? .ready : .missing
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    var isReady: Bool { state == .ready }

    static var sizeLabel: String { ByteCountFormatter.string(fromByteCount: WhisperFiles.totalSize, countStyle: .file) }
    var isDownloading: Bool { if case .downloading = state { true } else { false } }

    func download() {
        guard !isDownloading else { return }
        cancelled = false
        state = .downloading(0)
        Task {
            do {
                try FileManager.default.createDirectory(at: WhisperFiles.dir, withIntermediateDirectories: true)
                var done: Int64 = 0
                for file in WhisperFiles.all where !WhisperFiles.isInstalled(file) {
                    try await fetch(file, alreadyDone: done)
                    done += file.size
                }
                state = WhisperFiles.isInstalled ? .ready : .failed("The download didn't finish. Try again.")
            } catch {
                state = cancelled ? .missing : .failed(Self.message(for: error))
            }
            task = nil
            observation = nil
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
    }

    func delete() {
        cancel()
        for file in WhisperFiles.all { try? FileManager.default.removeItem(at: WhisperFiles.path(file)) }
        state = .missing
    }

    private func fetch(_ file: WhisperFiles.File, alreadyDone: Int64) async throws {
        let total = Double(WhisperFiles.totalSize)
        let destination = WhisperFiles.path(file)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: file.url) { temp, response, error in
                // `temp` is deleted when this handler returns, so move it now.
                do {
                    if let error { throw error }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard let temp, (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                    let size = (try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
                    guard size == file.size else { throw URLError(.cannotDecodeContentData) }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = (Double(alreadyDone) + progress.fractionCompleted * Double(file.size)) / total
                Task { @MainActor in
                    guard let self, self.isDownloading else { return }
                    self.state = .downloading(min(fraction, 1))
                }
            }
            self.task = task
            task.resume()
        }
    }

    private static func message(for error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost: "You're offline. Connect and try again."
        case .cannotDecodeContentData, .badServerResponse: "The download was incomplete. Try again."
        default: "Download failed: \(error.localizedDescription)"
        }
    }
}

/// Transcribes a whole recording with whisper.cpp (Metal-accelerated) after it's been saved.
enum WhisperTranscriber {
    /// Shared with the C callbacks: progress goes out, cancellation comes in.
    private final class Callbacks: @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool { lock.withLock { _cancelled } }
        func cancel() { lock.withLock { _cancelled = true } }
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
    }

    static func transcribe(_ url: URL, languageCode: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard WhisperFiles.isInstalled else { throw WhisperError.modelMissing }
        let callbacks = Callbacks(onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let samples = try loadSamples(url)
                try Task.checkCancellation()
                let text = try run(samples, languageCode: languageCode, callbacks: callbacks)
                try Task.checkCancellation()
                return text
            }.value
        } onCancel: {
            callbacks.cancel()
        }
    }

    private static func run(_ samples: [Float], languageCode: String, callbacks: Callbacks) throws -> String {
        whisper_log_set({ _, _, _ in }, nil)
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        contextParams.flash_attn = true
        guard let context = whisper_init_from_file_with_params(WhisperFiles.path(WhisperFiles.model).path, contextParams) else {
            throw WhisperError.loadFailed
        }
        defer { whisper_free(context) }

        // Matches the settings tested on real lecture audio: beam search, and VAD so silence is
        // skipped instead of hallucinated over.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.vad = true
        params.vad_params = whisper_vad_default_params()

        let box = Unmanaged.passRetained(callbacks)
        defer { box.release() }
        params.progress_callback = { _, _, progress, data in
            guard let data else { return }
            Unmanaged<Callbacks>.fromOpaque(data).takeUnretainedValue().onProgress(Double(progress) / 100)
        }
        params.progress_callback_user_data = box.toOpaque()
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<Callbacks>.fromOpaque(data).takeUnretainedValue().cancelled
        }
        params.abort_callback_user_data = box.toOpaque()

        let language = strdup(languageCode)
        let vadPath = strdup(WhisperFiles.path(WhisperFiles.vad).path)
        defer {
            free(language)
            free(vadPath)
        }
        params.language = UnsafePointer(language)
        params.vad_model_path = UnsafePointer(vadPath)
        // Feeding past text (or a vocabulary prompt) back in sends Whisper into repetition loops on long
        // lectures; tested on a real hour-long lecture, so both are off. Slides fix terms in the notes instead.
        params.no_context = true
        params.n_max_text_ctx = 0

        let code = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        if callbacks.cancelled { throw CancellationError() }
        guard code == 0 else { throw WhisperError.failed(code) }

        var lines: [String] = []
        for i in 0..<whisper_full_n_segments(context) {
            guard let cText = whisper_full_get_segment_text(context, i) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        let transcript = collapseRepeats(lines.joined(separator: " "))
        guard !transcript.isEmpty else { throw WhisperError.empty }
        return transcript
    }

    /// Safety net for Whisper's repetition loops ("all 4, all 4, all 4, …"): any phrase of up to
    /// `maxPhrase` words repeated back to back `threshold`+ times is cut down to two copies.
    static func collapseRepeats(_ text: String, maxPhrase: Int = 25, threshold: Int = 4) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for n in 1...maxPhrase where words.count >= n * threshold {
            var out: [String] = []
            out.reserveCapacity(words.count)
            var i = 0
            while i < words.count {
                if i + n * threshold <= words.count {
                    let phrase = words[i..<(i + n)]
                    var repeats = 1
                    while i + (repeats + 1) * n <= words.count,
                          words[(i + repeats * n)..<(i + (repeats + 1) * n)].elementsEqual(phrase) {
                        repeats += 1
                    }
                    if repeats >= threshold {
                        out.append(contentsOf: phrase)
                        out.append(contentsOf: phrase)
                        i += repeats * n
                        continue
                    }
                }
                out.append(words[i])
                i += 1
            }
            words = out
        }
        return words.joined(separator: " ")
    }

    /// Decodes the recording to the 16 kHz mono floats Whisper expects.
    static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw WhisperError.unreadableAudio }
        converter.downmix = true

        let chunk: AVAudioFrameCount = 1 << 16
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * 16_000 / input.sampleRate) + Int(chunk))
        var endOfFile = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: chunk) else { throw WhisperError.unreadableAudio }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                guard !endOfFile, let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer, frameCount: chunk)
                } catch {
                    endOfFile = true
                }
                if buffer.frameLength == 0 {
                    endOfFile = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if out.frameLength > 0, let channel = out.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && endOfFile) { break }
        }
        guard !samples.isEmpty else { throw WhisperError.unreadableAudio }
        return samples
    }
}
