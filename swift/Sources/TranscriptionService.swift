import AVFoundation
import Foundation
import WhisperKit
import FluidAudio
import SpeakerMatchingCore

struct MeetingTranscriptionResult {
    var transcript: String
    var detectedSpeakers: [DetectedSpeaker]
}

/// Intermediate result after the WhisperKit ASR pass but before diarization.
/// Stored as a checkpoint so a crash mid-diarization doesn't lose the expensive ASR output.
struct RawTranscriptionResult {
    let segments: [TranscriptionSegment]
    let rawText: String
}

class TranscriptionService {
    private var whisperKit: WhisperKit?
    private(set) var diarizer: OfflineDiarizerManager?
    private var currentModelId: String = ""

    /// Ensure the diarizer is loaded (without loading WhisperKit). Used by
    /// PeopleStore's re-embed flow when we only need embeddings, not
    /// transcription.
    func prepareDiarizer() async throws -> OfflineDiarizerManager {
        if let existing = diarizer { return existing }
        let diaConfig = OfflineDiarizerConfig()
        let dia = OfflineDiarizerManager(config: diaConfig)
        try await dia.prepareModels()
        diarizer = dia
        return dia
    }

    // MARK: - Setup

    func prepare(
        model: String,
        downloadProgress: ((Double) -> Void)? = nil,
        statusCallback: ((String) -> Void)? = nil
    ) async throws {
        let modelId = model.isEmpty ? "openai_whisper-large-v3" : model

        if whisperKit == nil || currentModelId != modelId {
            // Download (or verify cache) with progress, then init WhisperKit from the local folder.
            statusCallback?("Downloading model \(modelId)...")
            let modelFolder = try await WhisperKit.download(
                variant: modelId,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { progress in
                    downloadProgress?(progress.fractionCompleted)
                }
            )
            downloadProgress?(1.0)
            statusCallback?("Loading model...")

            let config = WhisperKitConfig(
                model: modelId,
                modelRepo: "argmaxinc/whisperkit-coreml",
                modelFolder: modelFolder.path,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            currentModelId = modelId
        }

        if diarizer == nil {
            statusCallback?("Loading diarizer...")
            let diaConfig = OfflineDiarizerConfig()
            diarizer = OfflineDiarizerManager(config: diaConfig)
            try await diarizer?.prepareModels()
        }
    }

    // MARK: - Transcribe

    /// Full pipeline: ASR → diarization → speaker matching → formatted transcript.
    func transcribe(
        audioURL: URL,
        peopleStore: PeopleStore,
        languageOverride: String? = nil,
        progressCallback: ((String) -> Void)? = nil,
        downloadProgress: ((Double) -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        let raw = try await transcribeAudio(
            audioURL: audioURL,
            languageOverride: languageOverride,
            progressCallback: progressCallback,
            downloadProgress: downloadProgress
        )
        return try await diarizeAndMatch(
            audioURL: audioURL,
            whisperSegments: raw.segments,
            peopleStore: peopleStore,
            progressCallback: progressCallback
        )
    }

    // MARK: - Phase 1: ASR (the expensive step)

    /// Run WhisperKit transcription only. Returns raw segments that can be
    /// serialized as a checkpoint before the diarization pass.
    func transcribeAudio(
        audioURL: URL,
        languageOverride: String? = nil,
        progressCallback: ((String) -> Void)? = nil,
        downloadProgress: ((Double) -> Void)? = nil
    ) async throws -> RawTranscriptionResult {
        let model = Preferences.shared.whisperModel
        progressCallback?("Loading models...")
        try await prepare(
            model: model,
            downloadProgress: downloadProgress,
            statusCallback: progressCallback
        )

        guard let whisper = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        progressCallback?("Transcribing audio...")
        let languageInput = languageOverride ?? Preferences.shared.meetingLanguage
        let language = Self.resolveLanguageCode(languageInput)

        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            sampleLength: 224
        )

        let domainTerms = Preferences.shared.domainTerms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !domainTerms.isEmpty, let tokenizer = whisper.tokenizer {
            let promptText = domainTerms.joined(separator: " ")
            let tokens = tokenizer.encode(text: " " + promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                options.usePrefillPrompt = true
                NSLog("[TranscriptionService] Domain terms prompt: \"\(promptText)\" → \(tokens.count) tokens")
            }
        }

        NSLog("[TranscriptionService] Starting WhisperKit transcription for: \(audioURL.lastPathComponent)")
        NSLog("[TranscriptionService] Model: \(currentModelId), Language: \(language ?? "auto")")

        let whisperResults = try await whisper.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        NSLog("[TranscriptionService] WhisperKit returned \(whisperResults.count) result(s)")
        if let first = whisperResults.first {
            NSLog("[TranscriptionService] Segments: \(first.segments.count)")
            for (i, seg) in first.segments.prefix(3).enumerated() {
                NSLog("[TranscriptionService]   Segment \(i): [\(seg.start)-\(seg.end)] \"\(seg.text.prefix(80))\"")
            }
        }

        guard let result = whisperResults.first, !result.segments.isEmpty else {
            NSLog("[TranscriptionService] ERROR: No results or empty segments")
            throw TranscriptionError.noResults
        }

        let rawText = result.segments.map { cleanWhisperText($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
        return RawTranscriptionResult(segments: result.segments, rawText: rawText)
    }

    // MARK: - Phase 2: Diarization + Speaker Matching

    /// Run diarization, merge with WhisperKit segments, match speakers, format transcript.
    /// Can be called independently to resume after a crash that happened between phases.
    func diarizeAndMatch(
        audioURL: URL,
        whisperSegments: [TranscriptionSegment],
        peopleStore: PeopleStore,
        progressCallback: ((String) -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        // Ensure diarizer is loaded (may already be from Phase 1)
        if diarizer == nil {
            progressCallback?("Loading diarizer...")
            _ = try await prepareDiarizer()
        }

        // Step 1: Diarize with FluidAudio
        progressCallback?("Identifying speakers...")
        var diarizedSegments: [DiarizedSegment] = []
        var speakerDB: [String: [Float]] = [:]

        if let diarizer = diarizer {
            do {
                let diaResult = try await diarizer.process(audioURL)
                diarizedSegments = diaResult.segments.map { seg in
                    DiarizedSegment(
                        speakerId: seg.speakerId,
                        startTime: seg.startTimeSeconds,
                        endTime: seg.endTimeSeconds,
                        embedding: seg.embedding,
                        qualityScore: seg.qualityScore
                    )
                }
                speakerDB = diaResult.speakerDatabase ?? [:]
            } catch {
                print("Diarization failed: \(error). Continuing without speaker labels.")
            }
        }

        // Step 2: Merge transcription with diarization
        progressCallback?("Matching speakers...")
        let mergedSegments = mergeTranscriptionWithDiarization(
            whisperSegments: whisperSegments,
            diarization: diarizedSegments
        )

        // Step 3: Match speaker embeddings against People library (with dedup)
        var speakerNameMap: [String: String] = [:]
        var detectedSpeakers: [DetectedSpeaker] = []

        struct SpeakerCandidate {
            let label: String
            let embedding: [Float]
            let sampleStart: Double
            let sampleEnd: Double
            let qualityScore: Float?
            let captureSource: AudioCaptureSource
        }

        let uniqueSpeakers = Set(mergedSegments.map(\.speakerLabel))
        var candidates: [SpeakerCandidate] = []
        for label in uniqueSpeakers {
            let spkId = label.replacingOccurrences(of: "Speaker ", with: "")
            let speakerSegs = diarizedSegments.filter { $0.speakerId == spkId }

            let embedding: [Float]
            if let db = speakerDB[spkId], !db.isEmpty {
                embedding = db
            } else if let segEmb = speakerSegs.first(where: { !$0.embedding.isEmpty })?.embedding {
                embedding = segEmb
            } else {
                speakerNameMap[label] = label
                continue
            }

            let window = Self.pickSampleWindow(for: spkId, allSegments: diarizedSegments)
            let quality = speakerSegs.map(\.qualityScore).max()
            let sourceReport = AudioSourceEnergyClassifier.analyze(
                finalAudioURL: audioURL,
                windows: speakerSegs.map { Double($0.startTime)...Double($0.endTime) }
            )
            candidates.append(SpeakerCandidate(
                label: label,
                embedding: embedding,
                sampleStart: window.start,
                sampleEnd: window.end,
                qualityScore: quality,
                captureSource: sourceReport.source
            ))
        }

        struct MatchTriple {
            let speakerLabel: String
            let person: Person
            let score: Float
        }

        let autoThreshold: Float = Preferences.shared.autoMatchThreshold
        var allTriples: [MatchTriple] = []
        let allPeople = await MainActor.run { peopleStore.people }
        for candidate in candidates {
            for person in allPeople {
                let score = await MainActor.run {
                    peopleStore.bestSimilarity(
                        embedding: candidate.embedding,
                        source: candidate.captureSource,
                        to: person
                    )
                }
                if score >= autoThreshold {
                    allTriples.append(MatchTriple(speakerLabel: candidate.label, person: person, score: score))
                }
            }
        }

        allTriples.sort { $0.score > $1.score }
        var assignedPersonIDs = Set<UUID>()
        var assignedSpeakers = Set<String>()
        var speakerToMatch: [String: (person: Person, score: Float)] = [:]

        for triple in allTriples {
            if assignedPersonIDs.contains(triple.person.id) { continue }
            if assignedSpeakers.contains(triple.speakerLabel) { continue }
            speakerToMatch[triple.speakerLabel] = (triple.person, triple.score)
            assignedPersonIDs.insert(triple.person.id)
            assignedSpeakers.insert(triple.speakerLabel)
        }

        for candidate in candidates {
            let matchResult = await MainActor.run {
                peopleStore.matchWithRecommendations(
                    embedding: candidate.embedding,
                    source: candidate.captureSource,
                    autoThreshold: autoThreshold,
                    recommendThreshold: Preferences.shared.recommendThreshold
                )
            }

            let autoMatch = speakerToMatch[candidate.label]
            let name = autoMatch?.person.name ?? candidate.label
            speakerNameMap[candidate.label] = name

            let filteredRecs = matchResult.recommendations.filter { rec in
                if rec.person.id == autoMatch?.person.id { return false }
                if assignedPersonIDs.contains(rec.person.id) && autoMatch?.person.id != rec.person.id {
                    return false
                }
                return true
            }

            detectedSpeakers.append(DetectedSpeaker(
                label: candidate.label,
                embedding: candidate.embedding,
                matchedPerson: autoMatch?.person,
                matchScore: autoMatch?.score,
                assignedName: name,
                sampleStartTime: candidate.sampleStart,
                sampleEndTime: candidate.sampleEnd,
                sampleQuality: candidate.qualityScore,
                captureSource: candidate.captureSource,
                recommendations: filteredRecs
            ))
        }

        let transcript = formatTranscript(mergedSegments, speakerNames: speakerNameMap)

        return MeetingTranscriptionResult(
            transcript: transcript,
            detectedSpeakers: detectedSpeakers
        )
    }

    // MARK: - Merge Whisper + Diarization

    private struct MergedSegment {
        let startTime: Float
        let endTime: Float
        let text: String
        let speakerLabel: String
    }

    private struct DiarizedSegment {
        let speakerId: String
        let startTime: Float
        let endTime: Float
        let embedding: [Float]
        let qualityScore: Float
    }

    // MARK: - Sample window selection

    /// Pick the best audio window to store as a voice sample for `speakerId`,
    /// given every diarized segment in the meeting. Prefers:
    ///   1. Long, uninterrupted segments that don't overlap with another
    ///      speaker by more than ~0.2s.
    ///   2. Clamped to [3s, 15s] — too short embeds poorly, too long wastes
    ///      storage and usually drifts across topics.
    ///   3. Trims the first 0.5s to skip utterance onsets and microphone
    ///      transients, when the segment is long enough to afford it.
    ///
    /// Falls back to the earliest segment (first 10s) when no clean window
    /// can be found.
    private static func pickSampleWindow(
        for speakerId: String,
        allSegments: [DiarizedSegment]
    ) -> (start: Double, end: Double) {
        let own = allSegments.filter { $0.speakerId == speakerId }
        let others = allSegments.filter { $0.speakerId != speakerId }

        // Compute "clean" duration (non-overlapped seconds) for each own segment
        // and rank by it.
        func cleanDuration(_ seg: DiarizedSegment) -> Float {
            let segDur = seg.endTime - seg.startTime
            guard segDur > 0 else { return 0 }
            var overlapped: Float = 0
            for o in others {
                let overlapStart = max(seg.startTime, o.startTime)
                let overlapEnd = min(seg.endTime, o.endTime)
                if overlapEnd > overlapStart {
                    overlapped += (overlapEnd - overlapStart)
                }
            }
            return max(0, segDur - overlapped)
        }

        let ranked = own
            .map { ($0, cleanDuration($0)) }
            .sorted { $0.1 > $1.1 }

        let minTarget: Float = 3
        let maxTarget: Float = 15

        for (seg, clean) in ranked where clean >= minTarget {
            // Use the segment's own bounds; trim onset if we have headroom.
            let headroom: Float = (seg.endTime - seg.startTime) > (minTarget + 1) ? 0.5 : 0
            let start = seg.startTime + headroom
            let end = min(start + maxTarget, seg.endTime)
            return (Double(start), Double(end))
        }

        // No clean window: fall back to first own segment, first 10s.
        if let first = own.first {
            let end = min(first.startTime + 10, first.endTime)
            return (Double(first.startTime), Double(end))
        }

        return (0, 10)
    }

    private func mergeTranscriptionWithDiarization(
        whisperSegments: [TranscriptionSegment],
        diarization: [DiarizedSegment]
    ) -> [MergedSegment] {
        if diarization.isEmpty {
            return whisperSegments.map { seg in
                MergedSegment(
                    startTime: seg.start,
                    endTime: seg.end,
                    text: cleanWhisperText(seg.text),
                    speakerLabel: "Speaker"
                )
            }
        }

        return whisperSegments.map { seg in
            let midpoint: Float = (seg.start + seg.end) / 2.0
            let speaker: String
            if let match = diarization.first(where: { midpoint >= $0.startTime && midpoint <= $0.endTime }) {
                speaker = "Speaker \(match.speakerId)"
            } else if let closest = diarization.min(by: {
                abs(($0.startTime + $0.endTime) / 2 - midpoint) < abs(($1.startTime + $1.endTime) / 2 - midpoint)
            }) {
                speaker = "Speaker \(closest.speakerId)"
            } else {
                speaker = "Speaker"
            }

            return MergedSegment(
                startTime: seg.start,
                endTime: seg.end,
                text: cleanWhisperText(seg.text),
                speakerLabel: speaker
            )
        }
    }

    // MARK: - Format

    private func cleanWhisperText(_ text: String) -> String {
        var cleaned = text
        // Strip Whisper control tokens like <|endoftext|>, <|en|>, <|nospeech|>
        let tokenPattern = #"<\|[^|]*\|>"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }
        // Strip bracketed silence/noise tokens Whisper sometimes emits as text:
        // [BLANK_AUDIO], [ Silence ], [Music], [inaudible], etc.
        let bracketPattern = #"\[\s*(BLANK_AUDIO|SILENCE|MUSIC|INAUDIBLE|NOISE|LAUGH(TER)?|APPLAUSE|SOUND|PAUSE|NO SPEECH)\s*\]"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern, options: .caseInsensitive) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merge consecutive segments sharing the same speaker when their gap is
    /// short (<= 5s). Keeps the output less "jumpy" for short utterances
    /// ("Yep.", "Okay.", "Right."). Preserves first segment's start and the
    /// last segment's end; joins text with spaces.
    private func mergeConsecutiveSameSpeaker(_ segments: [MergedSegment], maxGap: Float = 5.0) -> [MergedSegment] {
        guard !segments.isEmpty else { return segments }
        var out: [MergedSegment] = []
        for seg in segments {
            let text = cleanWhisperText(seg.text)
            guard !text.isEmpty else { continue }
            if let last = out.last,
               last.speakerLabel == seg.speakerLabel,
               (seg.startTime - last.endTime) <= maxGap {
                // Merge: keep last's startTime + speaker, extend end, join text
                let combined = MergedSegment(
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    text: last.text + " " + text,
                    speakerLabel: last.speakerLabel
                )
                out.removeLast()
                out.append(combined)
            } else {
                out.append(MergedSegment(
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: text,
                    speakerLabel: seg.speakerLabel
                ))
            }
        }
        return out
    }

    /// Format: [Speaker Name] [MM:SS]\nText
    private func formatTranscript(_ segments: [MergedSegment], speakerNames: [String: String]) -> String {
        let merged = mergeConsecutiveSameSpeaker(segments)
        return merged.compactMap { seg in
            let name = speakerNames[seg.speakerLabel] ?? seg.speakerLabel
            // Text was already cleaned in mergeConsecutiveSameSpeaker
            guard !seg.text.isEmpty else { return nil }
            let m = Int(seg.startTime) / 60
            let s = Int(seg.startTime) % 60
            return "[\(name)] [\(String(format: "%02d:%02d", m, s))]\n\(seg.text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Available Models

    static let availableModels: [(id: String, name: String, size: String)] = [
        ("openai_whisper-tiny", "Tiny", "75 MB"),
        ("openai_whisper-base", "Base", "142 MB"),
        ("openai_whisper-small", "Small", "466 MB"),
        ("openai_whisper-medium", "Medium", "1.5 GB"),
        ("openai_whisper-large-v3-turbo", "Large v3 Turbo", "1.5 GB"),
        ("openai_whisper-large-v3", "Large v3", "2.9 GB"),
    ]

    // MARK: - Language Resolution

    /// Convert user-friendly language input to a Whisper ISO code.
    /// - Single ISO code ("en", "da") → use directly
    /// - Single language name ("English") → map to code
    /// - Multiple languages ("Danish or English", "en, da") → auto-detect (nil)
    /// - Empty or unrecognized → auto-detect (nil)
    static func resolveLanguageCode(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()

        // If it's already a single 2-letter ISO code, use it
        if lower.count == 2, nameToCode.values.contains(lower) { return lower }

        // Count how many known languages appear in the input
        let matches = nameToCode.filter { lower.contains($0.key) || lower.contains($0.value) }

        if matches.count == 1 {
            // Exactly one language mentioned → use it
            return matches.first!.value
        } else if matches.count > 1 {
            // Multiple languages → auto-detect is better than guessing
            NSLog("[TranscriptionService] Multiple languages detected in '\(input)', using auto-detect")
            return nil
        }

        // No match → auto-detect
        NSLog("[TranscriptionService] Unrecognized language '\(input)', using auto-detect")
        return nil
    }

    private static let nameToCode: [String: String] = [
        "english": "en", "danish": "da", "german": "de", "french": "fr",
        "spanish": "es", "italian": "it", "portuguese": "pt", "dutch": "nl",
        "swedish": "sv", "norwegian": "no", "finnish": "fi", "polish": "pl",
        "russian": "ru", "chinese": "zh", "japanese": "ja", "korean": "ko",
        "arabic": "ar", "hindi": "hi", "turkish": "tr", "czech": "cs",
        "greek": "el", "hebrew": "he", "hungarian": "hu", "romanian": "ro",
        "ukrainian": "uk", "thai": "th", "vietnamese": "vi", "indonesian": "id",
    ]

    // MARK: - Math Utilities

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let normA = sqrt(a.reduce(Float(0)) { $0 + $1 * $1 })
        let normB = sqrt(b.reduce(Float(0)) { $0 + $1 * $1 })
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case noResults

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "Whisper model not loaded. Select a model in Settings."
            case .noResults: return "No transcription results produced."
            }
        }
    }
}
