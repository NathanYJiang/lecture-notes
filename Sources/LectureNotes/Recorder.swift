import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case micDenied, noDisplay, mixFailed, systemAudioDenied

    var errorDescription: String? {
        switch self {
        case .micDenied: "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .noDisplay: "No display found for system audio capture."
        case .mixFailed: "Couldn't mix mic and system audio."
        case .systemAudioDenied: "To record system audio, allow Lecture Notes in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app. Or switch to Mic only in Settings → Audio."
        }
    }
}

/// Captures the mic (AVAudioEngine) and optionally system audio (ScreenCaptureKit),
/// saving each to disk and streaming buffers to live transcribers.
final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    var onFailure: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var fileConverter: AVAudioConverter?
    private var micLive: LiveTranscriber?
    private var configObserver: NSObjectProtocol?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var systemLive: LiveTranscriber?
    private let systemQueue = DispatchQueue(label: "LectureNotes.systemAudio")

    private var dir: URL?

    func start(in dir: URL, mic: LiveTranscriber, system: LiveTranscriber?) async throws {
        self.dir = dir
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.micDenied }

        micLive = mic
        let format = engine.inputNode.outputFormat(forBus: 0)
        micFile = try AVAudioFile(forWriting: dir.appending(path: "mic.m4a"), settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 96_000,
        ])
        installTap()
        try engine.start()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterDeviceChange()
        }

        if let system {
            systemLive = system
            do {
                try await startSystemAudio(to: dir.appending(path: "system.m4a"))
            } catch {
                stopMic()
                throw error
            }
        }
    }

    /// Switching mics (e.g. AirPods connecting) reconfigures the engine; reattach and keep going.
    private func restartAfterDeviceChange() {
        guard micFile != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        do {
            try engine.start()
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.micFile != nil else { return }
                do { try self.engine.start() } catch { self.onFailure?() }
            }
        }
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.write(buffer)
            self.micLive?.append(buffer)
            self.onLevel?(Self.level(of: buffer))
        }
    }

    /// The file keeps the format it was opened with, so buffers from a newly connected mic get converted.
    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file = micFile else { return }
        let target = file.processingFormat
        if buffer.format == target {
            try? file.write(from: buffer)
            return
        }
        if fileConverter?.inputFormat != buffer.format {
            fileConverter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter = fileConverter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
        if error == nil, output.frameLength > 0 { try? file.write(from: output) }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 50))
    }

    private func startSystemAudio(to url: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.systemAudioDenied
        }
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        self.writer = writer
        self.writerInput = input
        sessionStarted = false

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid, let writer, let writerInput else { return }
        if !sessionStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            sessionStarted = true
        }
        if writerInput.isReadyForMoreMediaData {
            writerInput.append(buffer)
        }
        if let systemLive, let pcm = Self.pcmBuffer(from: buffer) {
            systemLive.append(pcm)
        }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private func stopMic() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micFile = nil
        fileConverter = nil
    }

    /// Stops capture, finalizes live transcription, and returns the audio file to keep.
    func stop() async throws -> URL {
        stopMic()
        guard let dir else { throw RecorderError.mixFailed }
        let micURL = dir.appending(path: "mic.m4a")

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
            systemQueue.sync {}
        }

        await micLive?.finish()
        await systemLive?.finish()
        micLive = nil
        systemLive = nil

        guard let writer, let writerInput, sessionStarted else { return micURL }
        writerInput.markAsFinished()
        await writer.finishWriting()
        self.writer = nil
        self.writerInput = nil

        // Export under a temp name so a quit mid-mix never leaves a half-written lecture.m4a behind.
        let mixed = dir.appending(path: "lecture.m4a")
        let partial = dir.appending(path: "lecture.partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await Self.mix([micURL, dir.appending(path: "system.m4a")], to: partial)
            try? FileManager.default.removeItem(at: mixed)
            try FileManager.default.moveItem(at: partial, to: mixed)
            return mixed
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return micURL
        }
    }

    private static func mix(_ urls: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try compTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.mixFailed
        }
        try await export.export(to: output, as: .m4a)
    }
}
