import AVFoundation
import Speech

/// Streams audio buffers into an on-device SpeechAnalyzer and reports
/// volatile (in-progress) and final text as it goes.
final class LiveTranscriber: @unchecked Sendable {
    private let onVolatile: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void

    /// Set only once `analyzer.start` has returned, so `finish` never finalizes an analyzer that isn't running.
    private var analyzer: SpeechAnalyzer?
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var converter: AVAudioConverter?
    private var finished = false
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingSeconds: Double = 0
    /// Guards state shared between `start`, `finish`, and the audio thread calling `append`.
    private let lock = NSLock()

    init(onVolatile: @escaping @Sendable (String) -> Void, onFinal: @escaping @Sendable (String) -> Void) {
        self.onVolatile = onVolatile
        self.onFinal = onFinal
    }

    func start(localeID: String, terms: [String]) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw TranscriberError.unsupportedLocale(localeID)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try? await analyzer.setContext(Self.context(for: terms))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let stopped = lock.withLock {
            if finished { return true }
            targetFormat = format
            self.continuation = continuation
            if let format {
                for buffer in pending { deliver(buffer, to: continuation, as: format) }
            }
            pending = []
            pendingSeconds = 0
            return false
        }
        if stopped { return }

        let results = Task { [onVolatile, onFinal] in
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                result.isFinal ? onFinal(text) : onVolatile(text)
            }
        }
        try await analyzer.start(inputSequence: stream)
        let finishedMeanwhile = lock.withLock {
            self.analyzer = analyzer
            resultsTask = results
            return finished
        }
        // `finish` ran while we were starting, so it couldn't finalize; do it here.
        if finishedMeanwhile {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = try? await results.value
        }
    }

    /// Downloads the on-device speech model ahead of time so the first recording starts instantly.
    static func preload(localeID: String) async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let install = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await install.downloadAndInstall()
        }
    }

    static func isSupported(localeID: String) async -> Bool {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) != nil
    }

    func updateTerms(_ terms: [String]) async {
        let analyzer = lock.withLock { self.analyzer }
        try? await analyzer?.setContext(Self.context(for: terms))
    }

    static func context(for terms: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        return context
    }

    /// Safe to call from the audio thread. Audio that arrives while the model is still loading is
    /// held (up to `maxPendingSeconds`) and fed in once it's ready, so the opening words aren't lost.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !finished else { return }
            guard let continuation, let targetFormat else {
                holdPending(buffer)
                return
            }
            deliver(buffer, to: continuation, as: targetFormat)
        }
    }

    static let maxPendingSeconds: Double = 30

    private func holdPending(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        pending.append(copy)
        pendingSeconds += Double(copy.frameLength) / copy.format.sampleRate
        while pendingSeconds > Self.maxPendingSeconds, let first = pending.first {
            pendingSeconds -= Double(first.frameLength) / first.format.sampleRate
            pending.removeFirst()
        }
    }

    /// Call with `lock` held.
    private func deliver(_ buffer: AVAudioPCMBuffer, to continuation: AsyncStream<AnalyzerInput>.Continuation, as targetFormat: AVAudioFormat) {
        if buffer.format == targetFormat {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    func finish() async {
        let (continuation, analyzer, results) = lock.withLock {
            finished = true
            pending = []
            defer { self.continuation = nil }
            return (self.continuation, self.analyzer, resultsTask)
        }
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await results?.value
    }
}
