import Foundation
import SwiftUI

// MARK: - Pipeline Step

enum PipelineStep: String {
    case pending, running, done, failed

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Recording Entry (persisted to recordings.json)

struct RecordingEntry: Identifiable, Codable {
    let id: String            // e.g. "20260410_140029"
    let filename: String      // e.g. "20260410_140029.wav"
    let date: Date
    var duration: Double      // seconds (preserved even after audio deletion)
    var title: String
    /// Status chain: recording → recorded → transcribing → transcribed_raw → transcribed → saved
    var status: String
    var transcript: String?
    var notes: String?
    var language: String?     // ISO code ("da", "en") or nil = use default
    /// JSON-serialized WhisperKit TranscriptionSegment array, stored after the ASR pass
    /// completes. Allows diarization to resume after a crash without re-running WhisperKit.
    /// Backward-compatible: old recordings without this field decode as nil.
    var rawSegmentsJSON: String?

    var dateFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    var durationFormatted: String {
        let s = Int(duration)
        let m = s / 60
        let sec = s % 60
        if m > 0 { return "\(m)m \(String(format: "%02d", sec))s" }
        return "\(sec)s"
    }

    var audioFileExists: Bool {
        let path = (Preferences.shared.recordingsPath as NSString)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: path)
    }

    var fileSizeBytes: Int64? {
        let path = (Preferences.shared.recordingsPath as NSString)
            .appendingPathComponent(filename)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    var fileSizeFormatted: String {
        guard let size = fileSizeBytes else { return "" }
        if size > 1_000_000 { return "\(size / 1_000_000) MB" }
        if size > 1_000 { return "\(size / 1_000) KB" }
        return "\(size) B"
    }
}

// MARK: - Person (persisted to ~/.meeting-recorder/people/)

struct Person: Identifiable, Codable {
    let id: UUID
    var name: String
    var samples: [VoiceSample]
    var createdAt: Date
    var updatedAt: Date
    var notes: String?

    var sampleCount: Int { samples.count }

    /// Total seconds of voice across all samples.
    var totalDuration: Double { samples.reduce(0) { $0 + $1.duration } }

    /// Most recent sample timestamp (or updatedAt as fallback).
    var lastSampleDate: Date { samples.map(\.createdAt).max() ?? updatedAt }

    /// Ignore the legacy `aggregateEmbedding` field in old people.json files.
    enum CodingKeys: String, CodingKey {
        case id, name, samples, createdAt, updatedAt, notes
    }
}

struct VoiceSample: Identifiable, Codable {
    let id: UUID
    var embedding: [Float]            // 256-dim WeSpeaker vector
    let duration: Double              // seconds
    let sourceRecordingID: String?    // which recording this was extracted from
    let createdAt: Date
    /// Embedding model marker used at extraction time. Used to detect stale
    /// embeddings after a model upgrade and offer re-embedding.
    var modelVersion: String?
    /// Optional quality score from the diarizer (higher = cleaner).
    var qualityScore: Float?

    var filename: String { "\(id.uuidString).caf" }
}

// MARK: - Detected Speaker (transient, for post-transcription UI)

struct DetectedSpeaker: Identifiable {
    let id = UUID()
    let label: String                 // "Speaker 0", "Speaker 1"
    let embedding: [Float]            // extracted embedding
    var matchedPerson: Person?        // if auto-matched above threshold
    var matchScore: Float?            // cosine similarity of auto-match (nil = no match)
    var assignedName: String          // final name (from match or user input)
    let sampleStartTime: Double       // start of representative segment
    let sampleEndTime: Double         // end of representative segment
    var sampleQuality: Float?         // diarizer quality hint for the chosen window
    var recommendations: [SpeakerRecommendation]  // top matches below auto-match threshold

    var isHighConfidence: Bool { matchedPerson != nil && (matchScore ?? 0) >= 0.62 }
    var hasRecommendations: Bool { !recommendations.isEmpty }

    var matchPercentage: String? {
        guard let score = matchScore else { return nil }
        return "\(Int(score * 100))%"
    }
}

struct SpeakerRecommendation: Identifiable {
    let id = UUID()
    let person: Person
    let similarity: Float             // cosine similarity score (0-1)

    var percentageString: String {
        "\(Int(similarity * 100))%"
    }
}

// MARK: - Contamination Warning (transient, surfaced when similarity is low)

struct ContaminationWarning: Identifiable {
    let id = UUID()
    let speaker: DetectedSpeaker
    let person: Person
    let similarity: Float             // max cosine vs. existing samples

    var percentageString: String {
        "\(Int(similarity * 100))%"
    }
}
