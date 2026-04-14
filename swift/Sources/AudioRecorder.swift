import AVFoundation
import Foundation

@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    // Mic recording (same as before)
    private var avRecorder: AVAudioRecorder?
    private(set) var startTime: Date?
    private(set) var recordingID: String?
    private(set) var filePath: URL?
    private(set) var duration: TimeInterval = 0

    // System-audio side channel (captures what would be heard through headphones/speakers)
    private var systemAudio: AnyObject?            // SystemAudioCapture (boxed for macOS <14 safety)
    private var systemAudioURL: URL?
    @Published var systemAudioWarning: String?      // non-nil if we couldn't start SCK

    var elapsed: TimeInterval {
        guard let start = startTime, isRecording else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func start() throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        systemAudioWarning = nil

        let recordingsDir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let id = Self.makeID()
        let micURL = recordingsDir.appendingPathComponent("\(id).mic.wav")
        let finalURL = recordingsDir.appendingPathComponent("\(id).wav")
        let sysURL = recordingsDir.appendingPathComponent("\(id).sys.wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        avRecorder = try AVAudioRecorder(url: micURL, settings: settings)
        guard let recorder = avRecorder, recorder.record() else {
            throw RecorderError.failedToStart
        }

        recordingID = id
        filePath = finalURL
        startTime = Date()
        isRecording = true

        // Best-effort: start system-audio capture (the other side of calls). If it fails we
        // continue with mic-only and the final WAV just equals the mic recording.
        if Preferences.shared.captureSystemAudio, #available(macOS 14.0, *) {
            let capture = SystemAudioCapture()
            systemAudio = capture
            systemAudioURL = sysURL
            Task.detached { [weak self] in
                do {
                    try await capture.start(outputURL: sysURL)
                } catch {
                    await MainActor.run {
                        self?.systemAudioWarning = error.localizedDescription
                        NSLog("[AudioRecorder] System audio capture failed to start: \(error). Continuing with mic only.")
                    }
                }
            }
        }
    }

    func stop() async throws -> (id: String, url: URL, duration: TimeInterval) {
        let recordedDuration = avRecorder?.currentTime ?? 0
        avRecorder?.stop()
        let dur = recordedDuration > 0
            ? recordedDuration
            : Date().timeIntervalSince(startTime ?? Date())
        let id = recordingID ?? ""
        let finalURL = filePath ?? URL(fileURLWithPath: "")
        let sysURL = systemAudioURL
        let recordingsDir = finalURL.deletingLastPathComponent()
        let micURL = recordingsDir.appendingPathComponent("\(id).mic.wav")

        duration = dur
        isRecording = false
        avRecorder = nil
        recordingID = nil
        filePath = nil
        startTime = nil

        // Stop SCK capture then mix — awaited so the WAV is fully written before returning.
        let sysCapture = systemAudio
        systemAudio = nil
        systemAudioURL = nil

        try await Task.detached(priority: .userInitiated) {
            if #available(macOS 14.0, *), let capture = sysCapture as? SystemAudioCapture {
                await capture.stop()
            }
            // Small settle delay to ensure the SCK file is fully flushed.
            try? await Task.sleep(nanoseconds: 150_000_000)
            await Self.produceFinalMix(micURL: micURL, sysURL: sysURL, finalURL: finalURL)
        }.value

        return (id, finalURL, dur)
    }

    private static func makeID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    // MARK: - Offline mix of mic + system audio

    /// Produces the final 16kHz mono WAV at `finalURL` by summing mic + system audio.
    /// If the system-audio file is missing or empty, the mic recording is copied verbatim.
    private static func produceFinalMix(micURL: URL, sysURL: URL?, finalURL: URL) async {
        let fm = FileManager.default
        // If SCK didn't produce anything usable, just move mic to final.
        let hasSys: Bool = {
            guard let u = sysURL else { return false }
            guard let attrs = try? fm.attributesOfItem(atPath: u.path),
                  let size = attrs[.size] as? NSNumber else { return false }
            return size.intValue > 4096
        }()

        if !hasSys {
            // No system audio — promote mic.wav → final.wav
            _ = try? fm.removeItem(at: finalURL)
            do { try fm.moveItem(at: micURL, to: finalURL) } catch {
                NSLog("[AudioRecorder] rename mic → final failed: \(error)")
            }
            return
        }

        // Mix using AVAudioEngine offline rendering.
        do {
            try await Self.mix(micURL: micURL, sysURL: sysURL!, finalURL: finalURL)
            // Clean up side-channel files on success.
            _ = try? fm.removeItem(at: micURL)
            _ = try? fm.removeItem(at: sysURL!)
        } catch {
            NSLog("[AudioRecorder] offline mix failed, falling back to mic only: \(error)")
            _ = try? fm.removeItem(at: finalURL)
            try? fm.moveItem(at: micURL, to: finalURL)
        }
    }

    private static func mix(micURL: URL, sysURL: URL, finalURL: URL) async throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let sysFile = try AVAudioFile(forReading: sysURL)

        // Final format: same as existing pipeline — 16kHz mono.
        let targetSR: Double = 16_000
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSR,
            channels: 1,
            interleaved: false
        )!
        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: targetSR,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        _ = try? FileManager.default.removeItem(at: finalURL)
        let outFile = try AVAudioFile(forWriting: finalURL, settings: writeSettings)

        let micMono = try Self.readAndResample(file: micFile, to: outFormat)
        let sysMono = try Self.readAndResample(file: sysFile, to: outFormat)

        // Sum with soft clamp to avoid clipping; system output is usually quieter at the mic
        // so we keep both at unit gain and clamp.
        let n = max(micMono.frameLength, sysMono.frameLength)
        guard let mixed = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: n) else {
            throw RecorderError.failedToMix
        }
        mixed.frameLength = n
        guard let mixPtr = mixed.floatChannelData?[0],
              let micPtr = micMono.floatChannelData?[0],
              let sysPtr = sysMono.floatChannelData?[0] else {
            throw RecorderError.failedToMix
        }
        let micN = Int(micMono.frameLength)
        let sysN = Int(sysMono.frameLength)
        for i in 0..<Int(n) {
            let m = i < micN ? micPtr[i] : 0
            let s = i < sysN ? sysPtr[i] : 0
            var v = m + s
            if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
            mixPtr[i] = v
        }
        try outFile.write(from: mixed)
    }

    private static func readAndResample(file: AVAudioFile, to outFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            return AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1)!
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw RecorderError.failedToMix
        }
        try file.read(into: input)

        if inFormat.sampleRate == outFormat.sampleRate && inFormat.channelCount == 1 {
            return input
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError.failedToMix
        }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw RecorderError.failedToMix
        }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw convError ?? RecorderError.failedToMix
        }
        return output
    }

    enum RecorderError: LocalizedError {
        case alreadyRecording, failedToStart, failedToMix
        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording"
            case .failedToStart: return "Failed to start audio recording"
            case .failedToMix: return "Failed to mix mic and system audio"
            }
        }
    }
}
