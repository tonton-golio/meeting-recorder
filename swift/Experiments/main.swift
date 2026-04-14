import Foundation
import AVFoundation
import WhisperKit
import FluidAudio

let testClipPath = NSHomeDirectory() + "/.meeting-recorder/test/test-5min.wav"
let resultsDir = NSHomeDirectory() + "/.meeting-recorder/test/results"
try? FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)

func cleanText(_ text: String) -> String {
    var cleaned = text
    if let regex = try? NSRegularExpression(pattern: #"<\|[^|]*\|>"#) {
        cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
    }
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    let normA = sqrt(a.reduce(Float(0)) { $0 + $1 * $1 })
    let normB = sqrt(b.reduce(Float(0)) { $0 + $1 * $1 })
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (normA * normB)
}

Task {
    let audioURL = URL(fileURLWithPath: testClipPath)
    guard FileManager.default.fileExists(atPath: testClipPath) else {
        print("ERROR: No test clip at \(testClipPath). Run the previous experiment first to create it.")
        exit(1)
    }

    // =========================================
    // EXPERIMENT A: FluidAudio Diarization Only
    // =========================================
    print("=== EXPERIMENT A: FluidAudio Diarization ===")
    do {
        let start = Date()
        let config = OfflineDiarizerConfig()
        let diarizer = OfflineDiarizerManager(config: config)
        print("  Preparing models...")
        try await diarizer.prepareModels()
        print("  Models ready: \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

        print("  Processing audio...")
        let dStart = Date()
        let result = try await diarizer.process(audioURL)
        let dTime = Date().timeIntervalSince(dStart)

        let speakers = Set(result.segments.map(\.speakerId)).sorted()
        print("  Done: \(result.segments.count) segments, \(speakers.count) speakers (\(speakers.joined(separator: ", ")))")
        print("  Time: \(String(format: "%.1f", dTime))s")

        var output = "FluidAudio Diarization Results\n"
        output += "Segments: \(result.segments.count)\n"
        output += "Speakers: \(speakers.count) (\(speakers.joined(separator: ", ")))\n"
        output += "Time: \(String(format: "%.1f", dTime))s\n\n"

        // Speaker database
        if let db = result.speakerDatabase {
            output += "--- SPEAKER EMBEDDINGS ---\n"
            for (spkId, emb) in db.sorted(by: { $0.key < $1.key }) {
                let norm = sqrt(emb.reduce(Float(0)) { $0 + $1 * $1 })
                output += "Speaker \(spkId): \(emb.count)-dim, norm=\(String(format: "%.3f", norm))\n"
            }

            // Similarity between speakers
            if speakers.count >= 2 {
                output += "\n--- SPEAKER SIMILARITY ---\n"
                for i in 0..<speakers.count {
                    for j in (i+1)..<speakers.count {
                        let sim = cosineSimilarity(db[speakers[i]]!, db[speakers[j]]!)
                        output += "Speaker \(speakers[i]) vs \(speakers[j]): \(String(format: "%.3f", sim))\n"
                    }
                }
            }
        }

        // Segment details
        output += "\n--- SEGMENTS ---\n"
        for seg in result.segments {
            let sM = Int(seg.startTimeSeconds) / 60, sS = Int(seg.startTimeSeconds) % 60
            let eM = Int(seg.endTimeSeconds) / 60, eS = Int(seg.endTimeSeconds) % 60
            let hasEmb = !seg.embedding.isEmpty ? "emb:\(seg.embedding.count)d" : "no-emb"
            output += "[\(String(format: "%02d:%02d", sM, sS))-\(String(format: "%02d:%02d", eM, eS))] Speaker \(seg.speakerId) (q:\(String(format: "%.2f", seg.qualityScore)), \(hasEmb))\n"
        }

        let path = (resultsDir as NSString).appendingPathComponent("diarization.txt")
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        print("  Saved: \(path)")
    } catch {
        print("  DIARIZATION ERROR: \(error)")
    }

    // =========================================
    // EXPERIMENT B: Combined Whisper + Diarization
    // =========================================
    print("\n=== EXPERIMENT B: Combined Whisper-Small + FluidAudio ===")
    do {
        let totalStart = Date()

        // Transcribe
        print("  Loading WhisperKit...")
        let wConfig = WhisperKitConfig(model: "openai_whisper-small", modelRepo: "argmaxinc/whisperkit-coreml")
        let whisper = try await WhisperKit(wConfig)

        // Load audio as float array for WhisperKit
        let inputFile = try AVAudioFile(forReading: audioURL)
        let sourceSR = inputFile.processingFormat.sampleRate
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFile.processingFormat, to: targetFormat)!
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: AVAudioFrameCount(inputFile.length))!
        try inputFile.read(into: sourceBuffer)
        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * 16000.0 / sourceSR) + 1024
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity)!
        var isDone = false
        converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if isDone { outStatus.pointee = .endOfStream; return nil }
            isDone = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        let samples = Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength)))

        print("  Transcribing...")
        let tStart = Date()
        let options = DecodingOptions(temperature: 0.0, temperatureFallbackCount: 5)
        let wResults = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let tTime = Date().timeIntervalSince(tStart)
        print("  Transcription: \(String(format: "%.1f", tTime))s, \(wResults.first?.segments.count ?? 0) segments")

        // Diarize
        print("  Diarizing...")
        let dConfig = OfflineDiarizerConfig()
        let diarizer = OfflineDiarizerManager(config: dConfig)
        try await diarizer.prepareModels()
        let dStart = Date()
        let diaResult = try await diarizer.process(audioURL)
        let dTime = Date().timeIntervalSince(dStart)
        print("  Diarization: \(String(format: "%.1f", dTime))s, \(diaResult.segments.count) segments")

        guard let wResult = wResults.first else { print("ERROR: No whisper result"); exit(1) }

        // Merge
        var output = "COMBINED: whisper-small + FluidAudio\n"
        output += "Transcription: \(String(format: "%.1f", tTime))s\n"
        output += "Diarization: \(String(format: "%.1f", dTime))s\n"
        output += "Total: \(String(format: "%.1f", Date().timeIntervalSince(totalStart)))s\n"
        output += "Whisper segments: \(wResult.segments.count)\n"
        output += "Diarization segments: \(diaResult.segments.count)\n"
        output += "Speakers: \(Set(diaResult.segments.map(\.speakerId)).sorted())\n\n"
        output += "--- MERGED TRANSCRIPT ---\n\n"

        var prevSpeaker = ""
        for seg in wResult.segments {
            let text = cleanText(seg.text)
            guard !text.isEmpty else { continue }

            let midpoint = (seg.start + seg.end) / 2.0
            let speaker: String
            if let match = diaResult.segments.first(where: { midpoint >= $0.startTimeSeconds && midpoint <= $0.endTimeSeconds }) {
                speaker = "Speaker \(match.speakerId)"
            } else if let closest = diaResult.segments.min(by: { abs(($0.startTimeSeconds + $0.endTimeSeconds)/2 - midpoint) < abs(($1.startTimeSeconds + $1.endTimeSeconds)/2 - midpoint) }) {
                speaker = "Speaker \(closest.speakerId)"
            } else {
                speaker = "Unknown"
            }

            let m = Int(seg.start) / 60, s = Int(seg.start) % 60

            if speaker != prevSpeaker {
                output += "\n[\(speaker)]\n"
                prevSpeaker = speaker
            }
            output += "  [\(String(format: "%02d:%02d", m, s))] \(text)\n"
        }

        // Speaker similarity
        if let db = diaResult.speakerDatabase, db.count >= 2 {
            output += "\n--- SPEAKER SIMILARITY ---\n"
            let spks = db.keys.sorted()
            for i in 0..<spks.count {
                for j in (i+1)..<spks.count {
                    let sim = cosineSimilarity(db[spks[i]]!, db[spks[j]]!)
                    output += "Speaker \(spks[i]) vs \(spks[j]): \(String(format: "%.3f", sim))\n"
                }
            }
        }

        let path = (resultsDir as NSString).appendingPathComponent("combined.txt")
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        print("  Saved: \(path)")
        print("  Total pipeline: \(String(format: "%.1f", Date().timeIntervalSince(totalStart)))s")

    } catch {
        print("  COMBINED ERROR: \(error)")
    }

    print("\n=== ALL EXPERIMENTS DONE ===")
    print("Results: \(resultsDir)")
    exit(0)
}

RunLoop.main.run()
