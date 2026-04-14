import AVFoundation
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

    /// Start capturing system audio into `url`. Throws if permissions are missing or setup fails.
    func start(outputURL url: URL) async throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }

        // We don't actually need video, but SCK requires an SCContentFilter that references
        // a display. Pick the main display; exclude no apps so we get all system audio.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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

        try await stream.startCapture()
        isRunning = true
    }

    func stop() async {
        guard let stream = stream else { return }
        do { try await stream.stopCapture() } catch {
            NSLog("[SystemAudioCapture] stopCapture error: \(error)")
        }
        isRunning = false
        self.stream = nil
        // Ensure file handle is flushed/closed
        audioFile = nil
    }

    /// Returns true if at least one audio sample was seen during the capture.
    /// Useful for detecting silent system-audio output (e.g., no call was playing).
    var capturedAnyAudio: Bool { didSeeAnySamples }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
                // On-disk: 16-bit integer PCM to keep file size sane.
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
            } catch {
                NSLog("[SystemAudioCapture] failed to create AVAudioFile: \(error)")
                return
            }
        }

        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        // Only count non-silent frames so capturedAnyAudio means "we got real audio".
        if !didSeeAnySamples, Self.hasAudibleContent(pcmBuffer) {
            didSeeAnySamples = true
        }
        do { try audioFile?.write(from: pcmBuffer) } catch {
            NSLog("[SystemAudioCapture] write error: \(error)")
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[SystemAudioCapture] stream stopped with error: \(error)")
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

        var abl = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let sizeHint = Int(pcm.frameLength) * Int(fmt.channelCount) * MemoryLayout<Float>.size
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        _ = sizeHint
        // Copy bytes into the PCM buffer's channel pointers.
        let channelCount = Int(fmt.channelCount)
        withUnsafeMutablePointer(to: &abl) { ablPtr in
            let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
            for i in 0..<min(channelCount, buffers.count) {
                guard let src = buffers[i].mData,
                      let dstBuffers = pcm.floatChannelData else { continue }
                let frames = Int(pcm.frameLength)
                let dst = dstBuffers[i]
                memcpy(dst, src, frames * MemoryLayout<Float>.size)
            }
        }
        return pcm
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
        case alreadyRunning, noDisplays
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "System audio capture is already running"
            case .noDisplays: return "No displays available for ScreenCaptureKit"
            }
        }
    }
}
