import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the system audio output (what would be heard through the speakers/headphones)
/// using ScreenCaptureKit's audio-only stream. Requires macOS 14+ and Screen Recording
/// permission. Audio is written to a 48kHz stereo WAV. Offline-mixing into the final
/// recording is done by `AudioRecorder` on stop.
@available(macOS 14.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private let sampleQueue = DispatchQueue(label: "com.simplyai.meeting-recorder.sck-audio")
    private(set) var outputURL: URL?
    private(set) var isRunning = false
    private var didSeeAnySamples = false

    /// Called on the sample queue with the current RMS level (0.0–1.0) each time a buffer arrives.
    var levelCallback: ((Float) -> Void)?

    /// Called if the stream appears to be running but no audio samples have arrived.
    /// Indicates a likely stale TCC permission or SCK bug.
    var onSilentStreamDetected: (() -> Void)?

    private var sampleWatchdog: Task<Void, Never>?

    /// Start capturing system audio into `url`. Throws if permissions are missing or setup fails.
    func start(outputURL url: URL) async throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }

        // Pre-flight: check Screen Recording permission (TCC).
        // Don't throw — just log and request. On some macOS versions SCK works even
        // when preflight returns false, and the watchdog will catch real failures.
        if !CGPreflightScreenCaptureAccess() {
            debugLog("[SystemAudioCapture] CGPreflight returned false — requesting access, will attempt capture anyway")
            CGRequestScreenCaptureAccess()
        } else {
            debugLog("[SystemAudioCapture] Screen Recording permission confirmed")
        }

        debugLog("[SystemAudioCapture] Starting — requesting shareable content...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        debugLog("[SystemAudioCapture] Got content: \(content.displays.count) displays, \(content.applications.count) apps")
        guard let display = content.displays.first else {
            throw CaptureError.noDisplays
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Minimise video overhead — SCK requires a video stream to exist, but we only tap audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        // Audio
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        self.outputURL = url

        debugLog("[SystemAudioCapture] Starting capture stream...")
        try await stream.startCapture()
        debugLog("[SystemAudioCapture] Capture started successfully")
        isRunning = true

        // Watchdog: if no audio samples arrive within 4 seconds, the stream is
        // silently failing (common with stale TCC grants from ad-hoc re-signing).
        sampleWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.isRunning, self.audioFile == nil else { return }
            debugLog("[SystemAudioCapture] WARNING: No audio samples received after 4 seconds — stream is silent")
            self.onSilentStreamDetected?()
        }
    }

    func stop() async {
        sampleWatchdog?.cancel()
        sampleWatchdog = nil
        guard let stream = stream else { return }
        do { try await stream.stopCapture() } catch {
            debugLog("[SystemAudioCapture] stopCapture error: \(error)")
        }
        isRunning = false
        self.stream = nil
        audioFile = nil
    }

    /// Returns true if at least one audio sample was seen during the capture.
    var capturedAnyAudio: Bool { didSeeAnySamples }

    // MARK: - SCStreamOutput

    private var callbackCount = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        callbackCount += 1
        // Log first few callbacks to diagnose format issues
        if callbackCount <= 3 {
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            let ready = CMSampleBufferDataIsReady(sampleBuffer)
            let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
            let mediaType = fmtDesc.map { CMFormatDescriptionGetMediaType($0) } ?? 0
            debugLog("[SystemAudioCapture] callback #\(callbackCount): type=\(type.rawValue) ready=\(ready) samples=\(numSamples) mediaType=\(mediaType) (1 = audio)")
            if let fd = fmtDesc, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                debugLog("[SystemAudioCapture]   format: rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bitsPerCh=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame) framesPerPacket=\(asbd.mFramesPerPacket) formatID=\(asbd.mFormatID)")
            }
        }

        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let outputURL = outputURL else { return }

        // Lazily create AVAudioFile using the first sample's format
        if audioFile == nil {
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
                return
            }
            let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                interleaved: false
            )
            guard let format = fmt else { return }
            do {
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: asbd.mSampleRate,
                    AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                audioFile = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                // First audio sample arrived — cancel the watchdog
                sampleWatchdog?.cancel()
                sampleWatchdog = nil
            } catch {
                debugLog("[SystemAudioCapture] failed to create AVAudioFile: \(error)")
                return
            }
        }

        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else {
            if callbackCount <= 5 {
                debugLog("[SystemAudioCapture] pcmBuffer conversion FAILED for callback #\(callbackCount)")
            }
            return
        }
        if callbackCount <= 3 {
            debugLog("[SystemAudioCapture] pcmBuffer OK: frames=\(pcmBuffer.frameLength) channels=\(pcmBuffer.format.channelCount)")
        }
        if !didSeeAnySamples, Self.hasAudibleContent(pcmBuffer) {
            didSeeAnySamples = true
        }
        do { try audioFile?.write(from: pcmBuffer) } catch {
            debugLog("[SystemAudioCapture] write error: \(error)")
        }

        if let cb = levelCallback {
            cb(Self.rmsLevel(pcmBuffer))
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        debugLog("[SystemAudioCapture] stream stopped with error: \(error)")
        isRunning = false
    }

    // MARK: - Helpers

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let fmt = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate,
                  channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                  interleaved: false
              ) else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(numSamples)

        // Allocate an AudioBufferList sized for the actual channel count.
        // Non-interleaved stereo needs room for 2 AudioBuffers; a stack-declared
        // AudioBufferList only has room for 1, so the API returns kCMSampleBufferError_ArrayTooSmall.
        let channelCount = Int(fmt.channelCount)
        let ablPtr = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(ablPtr.unsafeMutablePointer) }
        let ablSize = MemoryLayout<AudioBufferList>.size
            + (max(channelCount, 1) - 1) * MemoryLayout<AudioBuffer>.stride

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr.unsafeMutablePointer,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        for i in 0..<min(channelCount, ablPtr.count) {
            guard let src = ablPtr[i].mData,
                  let dstBuffers = pcm.floatChannelData else { continue }
            let frames = Int(pcm.frameLength)
            memcpy(dstBuffers[i], src, frames * MemoryLayout<Float>.size)
        }
        return pcm
    }

    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sumSq: Float = 0
        let p = data[0]
        let stride = max(1, frames / 256)
        var count = 0
        for i in Swift.stride(from: 0, to: frames, by: stride) {
            sumSq += p[i] * p[i]
            count += 1
        }
        let rms = sqrtf(sumSq / Float(count))
        return min(1.0, rms * 3.0)
    }

    private static func hasAudibleContent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let threshold: Float = 0.0005
        for c in 0..<channels {
            let p = data[c]
            for i in stride(from: 0, to: frames, by: 64) {
                if abs(p[i]) > threshold { return true }
            }
        }
        return false
    }

    enum CaptureError: LocalizedError {
        case alreadyRunning, noDisplays, screenRecordingDenied
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "System audio capture is already running"
            case .noDisplays: return "No displays available for ScreenCaptureKit"
            case .screenRecordingDenied:
                return "Screen Recording permission not granted. If you recently rebuilt the app, the permission may be stale. Open System Settings > Privacy & Security > Screen Recording, toggle Meeting Recorder OFF then ON, and restart the app."
            }
        }
    }
}
