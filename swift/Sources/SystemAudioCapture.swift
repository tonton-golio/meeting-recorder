import AppKit
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
    private var pcmBufferCount = 0
    private var conversionFailureCount = 0
    private var framesWritten = 0
    private var audibleBufferCount = 0
    private var maxRMSLevel: Float = 0
    private var maxPeakLevel: Float = 0

    /// Called on the sample queue with the current RMS level (0.0–1.0) each time a buffer arrives.
    var levelCallback: ((Float) -> Void)?

    /// Called when the stream appears to be running but audio capture itself is unhealthy.
    var onCaptureIssueDetected: ((String) -> Void)?

    private var sampleWatchdog: Task<Void, Never>?

    struct CaptureReport {
        let callbackCount: Int
        let pcmBufferCount: Int
        let conversionFailureCount: Int
        let framesWritten: Int
        let audibleBufferCount: Int
        let maxRMSLevel: Float
        let maxPeakLevel: Float
        let outputFileSizeBytes: Int64?

        var capturedAudibleAudio: Bool {
            audibleBufferCount > 0 || maxPeakLevel > 0.0005
        }

        var warningMessage: String? {
            if callbackCount == 0 {
                return "System audio stream started but no audio buffers arrived. Screen Recording permission may be stale — toggle it off and on in System Settings, then restart the app."
            }
            if pcmBufferCount == 0, conversionFailureCount > 0 {
                return "System audio buffers arrived but could not be decoded. The remote side was not recorded."
            }
            if !capturedAudibleAudio {
                return "System audio captured silence — the remote side may not have been recorded."
            }
            return nil
        }

        var logLine: String {
            let size = outputFileSizeBytes.map(String.init) ?? "missing"
            return "callbacks=\(callbackCount) pcm=\(pcmBufferCount) conversionFailures=\(conversionFailureCount) frames=\(framesWritten) audibleBuffers=\(audibleBufferCount) maxRMS=\(String(format: "%.5f", maxRMSLevel)) maxPeak=\(String(format: "%.5f", maxPeakLevel)) fileBytes=\(size)"
        }
    }

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
        guard let display = Self.preferredDisplay(from: content) else {
            throw CaptureError.noDisplays
        }
        debugLog("[SystemAudioCapture] Selected display \(display.displayID) for capture filter")
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
            guard let self, self.isRunning else { return }
            if self.callbackCount == 0 {
                let message = "System audio stream started but no audio buffers arrived after 4 seconds"
                debugLog("[SystemAudioCapture] WARNING: \(message)")
                self.onCaptureIssueDetected?(message)
            } else if self.pcmBufferCount == 0, self.conversionFailureCount > 0 {
                let message = "System audio buffers arrived but PCM conversion is failing"
                debugLog("[SystemAudioCapture] WARNING: \(message)")
                self.onCaptureIssueDetected?(message)
            }
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

    func report() -> CaptureReport {
        let size: Int64? = outputURL.flatMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let value = attrs[.size] as? NSNumber else { return nil }
            return value.int64Value
        }
        return CaptureReport(
            callbackCount: callbackCount,
            pcmBufferCount: pcmBufferCount,
            conversionFailureCount: conversionFailureCount,
            framesWritten: framesWritten,
            audibleBufferCount: audibleBufferCount,
            maxRMSLevel: maxRMSLevel,
            maxPeakLevel: maxPeakLevel,
            outputFileSizeBytes: size
        )
    }

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

        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else {
            conversionFailureCount += 1
            if callbackCount <= 5 {
                debugLog("[SystemAudioCapture] pcmBuffer conversion FAILED for callback #\(callbackCount)")
            }
            return
        }
        pcmBufferCount += 1
        framesWritten += Int(pcmBuffer.frameLength)
        if callbackCount <= 3 {
            debugLog("[SystemAudioCapture] pcmBuffer OK: frames=\(pcmBuffer.frameLength) channels=\(pcmBuffer.format.channelCount)")
        }
        let rms = Self.rmsLevel(pcmBuffer)
        let peak = Self.peakLevel(pcmBuffer)
        maxRMSLevel = max(maxRMSLevel, rms)
        maxPeakLevel = max(maxPeakLevel, peak)
        if Self.hasAudibleContent(pcmBuffer) {
            audibleBufferCount += 1
            didSeeAnySamples = true
        }
        if audioFile == nil {
            do {
                audioFile = try AVAudioFile(forWriting: outputURL, settings: pcmBuffer.format.settings)
                sampleWatchdog?.cancel()
                sampleWatchdog = nil
            } catch {
                debugLog("[SystemAudioCapture] failed to create AVAudioFile: \(error)")
                return
            }
        }
        do { try audioFile?.write(from: pcmBuffer) } catch {
            debugLog("[SystemAudioCapture] write error: \(error)")
        }

        if let cb = levelCallback {
            cb(rms)
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

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channelCount = Int(fmt.channelCount)
        let inputBufferCount = isNonInterleaved ? channelCount : 1
        let ablPtr = AudioBufferList.allocate(maximumBuffers: inputBufferCount)
        defer { free(ablPtr.unsafeMutablePointer) }
        let ablSize = MemoryLayout<AudioBufferList>.size
            + (max(inputBufferCount, 1) - 1) * MemoryLayout<AudioBuffer>.stride

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

        guard let dstBuffers = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)

        if isFloat, isNonInterleaved {
            for channel in 0..<min(channelCount, ablPtr.count) {
                guard let src = ablPtr[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                memcpy(dstBuffers[channel], src, frames * MemoryLayout<Float>.size)
            }
        } else if isFloat {
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    dstBuffers[channel][frame] = src[frame * channelCount + channel]
                }
            }
        } else if bitsPerChannel == 16, isNonInterleaved {
            for channel in 0..<min(channelCount, ablPtr.count) {
                guard let src = ablPtr[channel].mData?.assumingMemoryBound(to: Int16.self) else { continue }
                for frame in 0..<frames {
                    dstBuffers[channel][frame] = Float(src[frame]) / Float(Int16.max)
                }
            }
        } else if bitsPerChannel == 16 {
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Int16.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    dstBuffers[channel][frame] = Float(src[frame * channelCount + channel]) / Float(Int16.max)
                }
            }
        } else {
            return nil
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

    private static func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        for c in 0..<channels {
            let p = data[c]
            for i in stride(from: 0, to: frames, by: 16) {
                peak = max(peak, abs(p[i]))
            }
        }
        return min(1.0, peak)
    }

    private static func preferredDisplay(from content: SCShareableContent) -> SCDisplay? {
        let displays = content.displays
        guard !displays.isEmpty else { return nil }
        let displayIDs = displays.map { String($0.displayID) }.joined(separator: ",")
        debugLog("[SystemAudioCapture] Available display IDs: \(displayIDs)")

        if let mouseDisplayID = displayIDContainingMouse(),
           let display = displays.first(where: { $0.displayID == mouseDisplayID }) {
            debugLog("[SystemAudioCapture] Mouse is on display \(mouseDisplayID)")
            return display
        }

        let mainDisplayID = CGMainDisplayID()
        if let display = displays.first(where: { $0.displayID == mainDisplayID }) {
            debugLog("[SystemAudioCapture] Falling back to main display \(mainDisplayID)")
            return display
        }

        return displays.first
    }

    private static func displayIDContainingMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where NSMouseInRect(mouse, screen.frame, false) {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let value = screen.deviceDescription[key] as? NSNumber {
                return CGDirectDisplayID(value.uint32Value)
            }
        }
        return nil
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
