import Foundation
import AVFoundation
import WhisperKit
import FluidAudio
import SpeakerMatchingCore

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

func energyString(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.6e", value)
}

func fileSizeString(_ url: URL?) -> String {
    guard let url,
          let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? NSNumber else { return "missing" }
    let bytes = size.doubleValue
    if bytes > 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
    if bytes > 1_000 { return String(format: "%.1f KB", bytes / 1_000) }
    return "\(Int(bytes)) B"
}

func summaryString(_ summary: AudioEnergySummary?) -> String {
    guard let summary else { return "missing" }
    return String(
        format: "dur=%6.1fs rms=%.6f peak=%.5f active=%5.1f%%",
        summary.duration,
        summary.rms,
        summary.peak,
        summary.activeRatio * 100
    )
}

func dbRatio(numerator: Double, denominator: Double) -> String {
    guard numerator > 0, denominator > 0 else { return "n/a" }
    return String(format: "%+.1f dB", 20 * log10(numerator / denominator))
}

func runCaptureAudit(arguments: [String]) {
    let fm = FileManager.default
    let recordingsDir = URL(fileURLWithPath: NSHomeDirectory() + "/.meeting-recorder/recordings")
    let target = arguments.first.map { URL(fileURLWithPath: $0) } ?? recordingsDir

    let finalURLs: [URL]
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
        let files = (try? fm.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        finalURLs = files
            .filter {
                $0.pathExtension == "wav"
                    && !$0.deletingPathExtension().lastPathComponent.hasSuffix(".mic")
                    && !$0.deletingPathExtension().lastPathComponent.hasSuffix(".sys")
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(25)
            .map { $0 }
    } else if fm.fileExists(atPath: target.path) {
        finalURLs = [target]
    } else {
        print("ERROR: target not found: \(target.path)")
        exit(1)
    }

    var output = "System Audio Capture Audit\n"
    output += "Target: \(target.path)\n"
    output += "Files: \(finalURLs.count)\n\n"
    output += "This audit reads final/mic/system WAVs and reports whether the system stem contains audible audio.\n\n"

    for finalURL in finalURLs {
        let stems = AudioSourceStemURLs.expectedSiblings(for: finalURL)
        let micURL = stems.existingMicrophoneURL
        let sysURL = stems.existingSystemURL
        let finalSummary = try? AudioEnergyAnalyzer.summarize(url: finalURL)
        let micSummary = micURL.flatMap { try? AudioEnergyAnalyzer.summarize(url: $0) }
        let sysSummary = sysURL.flatMap { try? AudioEnergyAnalyzer.summarize(url: $0) }

        output += "=== \(finalURL.lastPathComponent) ===\n"
        output += "final  \(fileSizeString(finalURL))  \(summaryString(finalSummary))\n"
        output += "mic    \(fileSizeString(micURL))  \(summaryString(micSummary))\n"
        output += "system \(fileSizeString(sysURL))  \(summaryString(sysSummary))\n"

        let diagnosis: String
        if sysURL == nil {
            diagnosis = "missing system stem: ScreenCaptureKit did not write a side-channel file"
        } else if let sysSummary, !sysSummary.hasAudibleContent {
            diagnosis = "system stem is silent: permission/output/app routing likely failed or nobody remote spoke"
        } else if let mic = micSummary, let sys = sysSummary, sys.rms > 0 {
            let relative = dbRatio(numerator: sys.rms, denominator: mic.rms)
            if sys.rms < max(0.001, mic.rms * 0.25) {
                diagnosis = "system stem is audible but much quieter than mic (\(relative)); automatic system gain should help"
            } else {
                diagnosis = "system stem looks audible (\(relative) vs mic)"
            }
        } else {
            diagnosis = "inconclusive"
        }
        output += "diagnosis: \(diagnosis)\n\n"
    }

    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmss"
    let path = (resultsDir as NSString).appendingPathComponent("capture-audit-\(df.string(from: Date())).txt")
    do {
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        print(output)
        print("Saved: \(path)")
    } catch {
        print("ERROR: could not save audit: \(error)")
        print(output)
    }
}

func runSourceAudit(audioURL: URL) async {
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
        print("ERROR: Audio file not found: \(audioURL.path)")
        exit(1)
    }

    print("=== EXPERIMENT: Source-aware speaker audit ===")
    print("  Audio: \(audioURL.path)")

    do {
        let start = Date()
        let config = OfflineDiarizerConfig()
        let diarizer = OfflineDiarizerManager(config: config)
        print("  Preparing diarizer...")
        try await diarizer.prepareModels()
        print("  Processing final mix...")
        let result = try await diarizer.process(audioURL)
        let speakers = Set(result.segments.map(\.speakerId)).sorted()

        var output = "Source-aware Speaker Audit\n"
        output += "Audio: \(audioURL.path)\n"
        output += "Speakers: \(speakers.count) (\(speakers.joined(separator: ", ")))\n"
        output += "Segments: \(result.segments.count)\n"
        output += "Time: \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n\n"
        output += "This audit compares each diarized speaker's energy in sibling stems:\n"
        output += "  \(audioURL.deletingPathExtension().lastPathComponent).mic.wav\n"
        output += "  \(audioURL.deletingPathExtension().lastPathComponent).sys.wav\n\n"
        output += "--- SPEAKER SOURCE AFFINITY ---\n"

        for speaker in speakers {
            let speakerSegments = result.segments.filter { $0.speakerId == speaker }
            let windows = speakerSegments.map {
                Double($0.startTimeSeconds)...Double($0.endTimeSeconds)
            }
            let report = AudioSourceEnergyClassifier.analyze(finalAudioURL: audioURL, windows: windows)
            output += "Speaker \(speaker): source=\(report.source.label)"
            output += " mic=\(energyString(report.microphoneEnergy))"
            output += " system=\(energyString(report.systemEnergy))"
            output += " segments=\(speakerSegments.count)\n"
        }

        if let db = result.speakerDatabase, db.count >= 2 {
            output += "\n--- SPEAKER SIMILARITY ---\n"
            let spks = db.keys.sorted()
            for i in 0..<spks.count {
                for j in (i + 1)..<spks.count {
                    let sim = cosineSimilarity(db[spks[i]]!, db[spks[j]]!)
                    output += "Speaker \(spks[i]) vs \(spks[j]): \(String(format: "%.3f", sim))\n"
                }
            }
        }

        output += "\n--- SEGMENTS ---\n"
        for seg in result.segments {
            let sM = Int(seg.startTimeSeconds) / 60, sS = Int(seg.startTimeSeconds) % 60
            let eM = Int(seg.endTimeSeconds) / 60, eS = Int(seg.endTimeSeconds) % 60
            output += "[\(String(format: "%02d:%02d", sM, sS))-\(String(format: "%02d:%02d", eM, eS))] Speaker \(seg.speakerId) q=\(String(format: "%.2f", seg.qualityScore))\n"
        }

        let stem = audioURL.deletingPathExtension().lastPathComponent
        let path = (resultsDir as NSString).appendingPathComponent("source-audit-\(stem).txt")
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        print("  Saved: \(path)")
    } catch {
        print("  SOURCE AUDIT ERROR: \(error)")
        exit(1)
    }
}

Task {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "capture-audit" {
        runCaptureAudit(arguments: Array(args.dropFirst()))
        exit(0)
    }

    if args.first == "source-audit" {
        guard args.count >= 2 else {
            print("Usage: swift run Experiments source-audit /path/to/recording.wav")
            exit(2)
        }
        await runSourceAudit(audioURL: URL(fileURLWithPath: args[1]))
        exit(0)
    }

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
