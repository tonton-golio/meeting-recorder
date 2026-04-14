import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

@MainActor
class PeopleStore: ObservableObject {
    @Published private(set) var people: [Person] = []

    /// Marker for the embedding model currently in use. If this changes across
    /// app versions, stored samples with a different `modelVersion` should be
    /// re-embedded from their stored audio via `reembedSample(...)`.
    static let currentEmbeddingModelVersion = "fluidaudio-wespeaker-v1"

    private var peopleDir: URL {
        URL(fileURLWithPath: Preferences.peoplePath)
    }

    private var indexURL: URL {
        peopleDir.appendingPathComponent("people.json")
    }

    // MARK: - Load / Save

    func loadAll() {
        let fm = FileManager.default
        try? fm.createDirectory(at: peopleDir, withIntermediateDirectories: true)

        // Migrate legacy voice prints if needed
        migrateFromLegacyVoicePrints()

        guard fm.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            people = try decoder.decode([Person].self, from: data)
            people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            print("Failed to load people index: \(error)")
        }
    }

    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(people)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("Failed to save people index: \(error)")
        }
    }

    // MARK: - Person CRUD

    func createPerson(
        name: String,
        audioURL: URL,
        startTime: Double,
        endTime: Double,
        embedding: [Float],
        qualityScore: Float? = nil
    ) async -> Person {
        let personID = UUID()
        let personDir = peopleDir.appendingPathComponent(personID.uuidString)
        try? FileManager.default.createDirectory(at: personDir, withIntermediateDirectories: true)

        let sampleID = UUID()
        let sampleURL = personDir.appendingPathComponent("\(sampleID.uuidString).caf")
        await extractAudioClip(from: audioURL, start: startTime, end: endTime, to: sampleURL)

        let sample = VoiceSample(
            id: sampleID,
            embedding: Self.normalize(embedding),
            duration: endTime - startTime,
            sourceRecordingID: audioURL.deletingPathExtension().lastPathComponent,
            createdAt: Date(),
            modelVersion: Self.currentEmbeddingModelVersion,
            qualityScore: qualityScore
        )

        let person = Person(
            id: personID,
            name: name,
            samples: [sample],
            createdAt: Date(),
            updatedAt: Date(),
            notes: nil
        )

        people.append(person)
        people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveIndex()
        return person
    }

    /// Create a person from an already-recorded audio clip file (e.g. from onboarding).
    /// The file is moved into the person's folder.
    func createPersonFromFile(
        name: String,
        existingClipURL: URL,
        duration: Double,
        embedding: [Float],
        qualityScore: Float? = nil,
        notes: String? = nil
    ) -> Person {
        let personID = UUID()
        let personDir = peopleDir.appendingPathComponent(personID.uuidString)
        try? FileManager.default.createDirectory(at: personDir, withIntermediateDirectories: true)

        let sampleID = UUID()
        let sampleURL = personDir.appendingPathComponent("\(sampleID.uuidString).caf")
        let fm = FileManager.default
        _ = try? fm.removeItem(at: sampleURL)
        do {
            try fm.moveItem(at: existingClipURL, to: sampleURL)
        } catch {
            _ = try? fm.copyItem(at: existingClipURL, to: sampleURL)
        }

        let sample = VoiceSample(
            id: sampleID,
            embedding: Self.normalize(embedding),
            duration: duration,
            sourceRecordingID: nil,
            createdAt: Date(),
            modelVersion: Self.currentEmbeddingModelVersion,
            qualityScore: qualityScore
        )

        let person = Person(
            id: personID,
            name: name,
            samples: [sample],
            createdAt: Date(),
            updatedAt: Date(),
            notes: notes
        )

        people.append(person)
        people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveIndex()
        return person
    }

    func rename(_ person: Person, to newName: String) {
        guard let idx = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[idx].name = newName
        people[idx].updatedAt = Date()
        people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveIndex()
    }

    func updateNotes(_ person: Person, notes: String) {
        guard let idx = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[idx].notes = notes.isEmpty ? nil : notes
        people[idx].updatedAt = Date()
        saveIndex()
    }

    func delete(_ person: Person) {
        let personDir = peopleDir.appendingPathComponent(person.id.uuidString)
        try? FileManager.default.removeItem(at: personDir)
        people.removeAll { $0.id == person.id }
        saveIndex()
    }

    // MARK: - Sample Management

    func addSample(
        to person: Person,
        audioURL: URL,
        startTime: Double,
        endTime: Double,
        embedding: [Float],
        qualityScore: Float? = nil
    ) async {
        guard let idx = people.firstIndex(where: { $0.id == person.id }) else { return }

        let personDir = peopleDir.appendingPathComponent(person.id.uuidString)
        try? FileManager.default.createDirectory(at: personDir, withIntermediateDirectories: true)

        let sampleID = UUID()
        let sampleURL = personDir.appendingPathComponent("\(sampleID.uuidString).caf")
        await extractAudioClip(from: audioURL, start: startTime, end: endTime, to: sampleURL)

        let sample = VoiceSample(
            id: sampleID,
            embedding: Self.normalize(embedding),
            duration: endTime - startTime,
            sourceRecordingID: audioURL.deletingPathExtension().lastPathComponent,
            createdAt: Date(),
            modelVersion: Self.currentEmbeddingModelVersion,
            qualityScore: qualityScore
        )

        people[idx].samples.append(sample)
        people[idx].updatedAt = Date()
        saveIndex()
    }

    /// Add a sample whose audio clip already exists at `existingClipURL`.
    /// The file is moved/copied into the person's folder. Used by the live
    /// "record new sample" flow in PeopleSheet.
    func addSampleFromFile(
        to person: Person,
        existingClipURL: URL,
        duration: Double,
        embedding: [Float],
        qualityScore: Float? = nil
    ) {
        guard let idx = people.firstIndex(where: { $0.id == person.id }) else { return }
        let personDir = peopleDir.appendingPathComponent(person.id.uuidString)
        try? FileManager.default.createDirectory(at: personDir, withIntermediateDirectories: true)

        let sampleID = UUID()
        let sampleURL = personDir.appendingPathComponent("\(sampleID.uuidString).caf")
        let fm = FileManager.default
        _ = try? fm.removeItem(at: sampleURL)
        do {
            try fm.moveItem(at: existingClipURL, to: sampleURL)
        } catch {
            // Fall back to copy
            _ = try? fm.copyItem(at: existingClipURL, to: sampleURL)
        }

        let sample = VoiceSample(
            id: sampleID,
            embedding: Self.normalize(embedding),
            duration: duration,
            sourceRecordingID: nil,
            createdAt: Date(),
            modelVersion: Self.currentEmbeddingModelVersion,
            qualityScore: qualityScore
        )

        people[idx].samples.append(sample)
        people[idx].updatedAt = Date()
        saveIndex()
    }

    func removeSample(_ sample: VoiceSample, from person: Person) {
        guard let idx = people.firstIndex(where: { $0.id == person.id }) else { return }
        let personDir = peopleDir.appendingPathComponent(person.id.uuidString)
        let sampleFile = personDir.appendingPathComponent(sample.filename)
        try? FileManager.default.removeItem(at: sampleFile)

        people[idx].samples.removeAll { $0.id == sample.id }

        if people[idx].samples.isEmpty {
            // No samples left — remove the person
            delete(people[idx])
        } else {
            people[idx].updatedAt = Date()
            saveIndex()
        }
    }

    // MARK: - Merge / Split

    /// Merge `source` into `destination`: moves all samples and deletes source.
    func merge(_ source: Person, into destination: Person) {
        guard source.id != destination.id else { return }
        guard let dstIdx = people.firstIndex(where: { $0.id == destination.id }),
              let srcIdx = people.firstIndex(where: { $0.id == source.id }) else { return }

        let fm = FileManager.default
        let srcDir = peopleDir.appendingPathComponent(source.id.uuidString)
        let dstDir = peopleDir.appendingPathComponent(destination.id.uuidString)
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        for sample in people[srcIdx].samples {
            let srcFile = srcDir.appendingPathComponent(sample.filename)
            let dstFile = dstDir.appendingPathComponent(sample.filename)
            if fm.fileExists(atPath: srcFile.path) {
                try? fm.moveItem(at: srcFile, to: dstFile)
            }
            people[dstIdx].samples.append(sample)
        }
        people[dstIdx].updatedAt = Date()

        // Clean up source folder and remove person
        try? fm.removeItem(at: srcDir)
        people.remove(at: srcIdx)
        saveIndex()
    }

    /// Split: move the given samples out of `person` into a new `Person` with `newName`.
    /// If all samples are moved, the original person is deleted.
    func split(person: Person, sampleIDs: Set<UUID>, newName: String) {
        guard !sampleIDs.isEmpty else { return }
        guard let srcIdx = people.firstIndex(where: { $0.id == person.id }) else { return }

        let fm = FileManager.default
        let srcDir = peopleDir.appendingPathComponent(person.id.uuidString)
        let newPersonID = UUID()
        let newDir = peopleDir.appendingPathComponent(newPersonID.uuidString)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        var moved: [VoiceSample] = []
        for sample in people[srcIdx].samples where sampleIDs.contains(sample.id) {
            let srcFile = srcDir.appendingPathComponent(sample.filename)
            let dstFile = newDir.appendingPathComponent(sample.filename)
            if fm.fileExists(atPath: srcFile.path) {
                try? fm.moveItem(at: srcFile, to: dstFile)
            }
            moved.append(sample)
        }
        people[srcIdx].samples.removeAll { sampleIDs.contains($0.id) }

        let newPerson = Person(
            id: newPersonID,
            name: newName,
            samples: moved,
            createdAt: Date(),
            updatedAt: Date(),
            notes: nil
        )
        people.append(newPerson)

        if people[srcIdx].samples.isEmpty {
            try? fm.removeItem(at: srcDir)
            people.remove(at: srcIdx)
        } else {
            people[srcIdx].updatedAt = Date()
        }

        people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveIndex()
    }

    // MARK: - Voice Matching (max-over-samples)

    /// Best cosine similarity between `embedding` and any sample of `person`.
    /// This is what matching uses — not the old mean "aggregate" vector —
    /// so a person with samples from different conditions (in-person / Zoom /
    /// headphones) can still be recognised in any of them.
    func bestSimilarity(embedding: [Float], to person: Person) -> Float {
        var best: Float = -1
        for sample in person.samples where !sample.embedding.isEmpty {
            let s = Self.cosineSimilarity(embedding, sample.embedding)
            if s > best { best = s }
        }
        return best < 0 ? 0 : best
    }

    /// Default auto-match threshold. Lowered from 0.62 to 0.55 after empirical
    /// calibration on a cleaned People library showed 0.50 cosine margin between
    /// intra- and inter-person distributions.
    nonisolated static let defaultAutoMatchThreshold: Float = 0.55

    /// Two-tier matching: returns auto-match if above autoThreshold,
    /// plus recommendations above recommendThreshold sorted by score.
    func matchWithRecommendations(
        embedding: [Float],
        autoThreshold: Float = PeopleStore.defaultAutoMatchThreshold,
        recommendThreshold: Float = 0.30
    ) -> (match: Person?, recommendations: [SpeakerRecommendation]) {
        var bestMatch: (person: Person, score: Float)?
        var recommendations: [SpeakerRecommendation] = []

        for person in people {
            let score = bestSimilarity(embedding: embedding, to: person)
            if score > (bestMatch?.score ?? 0) {
                bestMatch = (person, score)
            }
            if score > recommendThreshold {
                recommendations.append(SpeakerRecommendation(person: person, similarity: score))
            }
        }

        recommendations.sort { $0.similarity > $1.similarity }

        if let best = bestMatch, best.score >= autoThreshold {
            // Auto-matched — filter out the matched person from recommendations
            let filtered = recommendations.filter { $0.person.id != best.person.id }
            return (best.person, filtered)
        }

        return (nil, recommendations)
    }

    /// Simple match (returns best match above threshold, or nil)
    func match(embedding: [Float], threshold: Float = PeopleStore.defaultAutoMatchThreshold) -> Person? {
        let result = matchWithRecommendations(embedding: embedding, autoThreshold: threshold)
        return result.match
    }

    // MARK: - Name Lookup

    /// Case-insensitive, trim-matching lookup. Returns the first person whose
    /// name matches (used for duplicate-name guards in the confirmation UI).
    func personWithName(_ name: String) -> Person? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return people.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
    }

    // MARK: - Contamination Guard

    /// Default similarity below which `addSample` should warn the user that
    /// the new clip doesn't sound like this person's existing samples.
    /// Raised from 0.30 to 0.45 after the "Andreas Golles" incident showed
    /// 0.26–0.39 contaminated clips slipping through the old floor.
    static let contaminationThreshold: Float = 0.45

    /// Max cosine similarity between `embedding` and the person's existing
    /// samples. Returns nil when the person has no samples yet (no guard).
    func similarityToExistingSamples(embedding: [Float], person: Person) -> Float? {
        guard !person.samples.isEmpty else { return nil }
        return bestSimilarity(embedding: embedding, to: person)
    }

    // MARK: - Calibration helpers

    /// Returns pairs of cosine similarities (intra, inter) computed from the
    /// current People library. Used to visualise how separable the library is
    /// and suggest thresholds. Samples with empty embeddings are skipped.
    struct CalibrationStats {
        var intra: [Float]   // cosines between samples of the same person
        var inter: [Float]   // cosines between samples of different people
        var suggestedThreshold: Float?
    }

    func calibrationStats() -> CalibrationStats {
        var intra: [Float] = []
        var inter: [Float] = []

        for p in people {
            let samples = p.samples.filter { !$0.embedding.isEmpty }
            if samples.count >= 2 {
                for i in 0..<samples.count {
                    for j in (i + 1)..<samples.count {
                        intra.append(Self.cosineSimilarity(samples[i].embedding, samples[j].embedding))
                    }
                }
            }
        }

        for i in 0..<people.count {
            for j in (i + 1)..<people.count {
                for a in people[i].samples where !a.embedding.isEmpty {
                    for b in people[j].samples where !b.embedding.isEmpty {
                        inter.append(Self.cosineSimilarity(a.embedding, b.embedding))
                    }
                }
            }
        }

        let suggested = Self.suggestThreshold(intra: intra, inter: inter)
        return CalibrationStats(intra: intra, inter: inter, suggestedThreshold: suggested)
    }

    /// Pick the threshold where FAR == FRR (equal-error rate) — coarse grid search.
    private static func suggestThreshold(intra: [Float], inter: [Float]) -> Float? {
        guard !intra.isEmpty, !inter.isEmpty else { return nil }
        var best: (threshold: Float, diff: Float) = (0.5, .greatestFiniteMagnitude)
        var t: Float = 0.30
        while t <= 0.90 {
            // FRR: intra-person falling below t (false reject)
            let frr = Float(intra.filter { $0 < t }.count) / Float(intra.count)
            // FAR: inter-person reaching or exceeding t (false accept)
            let far = Float(inter.filter { $0 >= t }.count) / Float(inter.count)
            let diff = abs(frr - far)
            if diff < best.diff { best = (t, diff) }
            t += 0.01
        }
        return best.threshold
    }

    // MARK: - Library Health

    enum HealthIssueKind {
        case duplicateName(name: String, personIDs: [UUID])
        case lowConsistency(personID: UUID, personName: String, meanIntraCosine: Float)
        case staleSamples(count: Int)
    }

    struct HealthIssue: Identifiable {
        let id = UUID()
        let kind: HealthIssueKind
        var message: String {
            switch kind {
            case .duplicateName(let name, let ids):
                return "Duplicate name \"\(name)\" (\(ids.count) entries) — merge to prevent mis-attribution"
            case .lowConsistency(_, let name, let mean):
                return "\"\(name)\" has low sample consistency (\(Int(mean * 100))%) — likely contaminated"
            case .staleSamples(let n):
                return "\(n) sample\(n == 1 ? "" : "s") on outdated embedding model — re-compute"
            }
        }
        var iconName: String {
            switch kind {
            case .duplicateName: return "person.2.fill"
            case .lowConsistency: return "exclamationmark.triangle.fill"
            case .staleSamples: return "clock.arrow.circlepath"
            }
        }
    }

    /// Cached health issues. Recomputed whenever `people` changes by callers.
    var healthIssues: [HealthIssue] {
        var issues: [HealthIssue] = []

        // Duplicate names (case-insensitive)
        var byName: [String: [UUID]] = [:]
        for p in people {
            let key = p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            byName[key, default: []].append(p.id)
        }
        for (_, ids) in byName where ids.count > 1 {
            if let name = people.first(where: { $0.id == ids[0] })?.name {
                issues.append(HealthIssue(kind: .duplicateName(name: name, personIDs: ids)))
            }
        }

        // Low intra-person consistency
        for p in people {
            let samples = p.samples.filter { !$0.embedding.isEmpty }
            guard samples.count >= 2 else { continue }
            var sum: Float = 0
            var pairs = 0
            for i in 0..<samples.count {
                for j in (i + 1)..<samples.count {
                    sum += Self.cosineSimilarity(samples[i].embedding, samples[j].embedding)
                    pairs += 1
                }
            }
            let mean = pairs > 0 ? sum / Float(pairs) : 0
            if mean < 0.35 {
                issues.append(HealthIssue(kind: .lowConsistency(personID: p.id, personName: p.name, meanIntraCosine: mean)))
            }
        }

        // Stale samples
        let stale = staleSampleCount
        if stale > 0 {
            issues.append(HealthIssue(kind: .staleSamples(count: stale)))
        }

        return issues
    }

    var hasHealthIssues: Bool { !healthIssues.isEmpty }

    // MARK: - File Access

    func sampleURL(for sample: VoiceSample, person: Person) -> URL {
        peopleDir
            .appendingPathComponent(person.id.uuidString)
            .appendingPathComponent(sample.filename)
    }

    func personDirectory(for person: Person) -> URL {
        peopleDir.appendingPathComponent(person.id.uuidString)
    }

    // MARK: - Re-embed from stored audio

    /// Samples whose `modelVersion` doesn't match the current one.
    var staleSampleCount: Int {
        people.reduce(0) { count, p in
            count + p.samples.filter { ($0.modelVersion ?? "") != Self.currentEmbeddingModelVersion }.count
        }
    }

    /// Re-extract the embedding for a single sample from its stored audio using
    /// `diarizer`. Picks the highest-quality segment. Silently leaves the
    /// sample unchanged on failure.
    func reembedSample(_ sample: VoiceSample, for person: Person, using diarizer: OfflineDiarizerManager) async {
        let url = sampleURL(for: sample, person: person)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let result = try await diarizer.process(url)
            // Prefer the highest-quality segment; fall back to first non-empty.
            let best = result.segments
                .filter { !$0.embedding.isEmpty }
                .max(by: { $0.qualityScore < $1.qualityScore })
            let newEmbedding: [Float]
            let newQuality: Float?
            if let best {
                newEmbedding = best.embedding
                newQuality = best.qualityScore
            } else if let db = result.speakerDatabase?.values.first(where: { !$0.isEmpty }) {
                newEmbedding = db
                newQuality = nil
            } else {
                return
            }

            guard let pIdx = people.firstIndex(where: { $0.id == person.id }),
                  let sIdx = people[pIdx].samples.firstIndex(where: { $0.id == sample.id }) else { return }
            people[pIdx].samples[sIdx].embedding = Self.normalize(newEmbedding)
            people[pIdx].samples[sIdx].modelVersion = Self.currentEmbeddingModelVersion
            if let q = newQuality { people[pIdx].samples[sIdx].qualityScore = q }
            people[pIdx].updatedAt = Date()
        } catch {
            NSLog("[PeopleStore] Re-embed failed for sample \(sample.id): \(error)")
        }
    }

    /// Re-embed every sample in the library using `diarizer`. Saves once at
    /// the end. Returns number of samples successfully re-embedded.
    @discardableResult
    func reembedAll(using diarizer: OfflineDiarizerManager) async -> Int {
        var count = 0
        let snapshot = people
        for person in snapshot {
            for sample in person.samples {
                let before = people.first(where: { $0.id == person.id })?
                    .samples.first(where: { $0.id == sample.id })?.embedding
                await reembedSample(sample, for: person, using: diarizer)
                let after = people.first(where: { $0.id == person.id })?
                    .samples.first(where: { $0.id == sample.id })?.embedding
                if let before, let after, before != after { count += 1 }
            }
        }
        saveIndex()
        return count
    }

    // MARK: - Math Utilities

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let normA = sqrt(a.reduce(Float(0)) { $0 + $1 * $1 })
        let normB = sqrt(b.reduce(Float(0)) { $0 + $1 * $1 })
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - Audio Extraction

    private func extractAudioClip(from sourceURL: URL, start: Double, end: Double, to destURL: URL) async {
        let asset = AVURLAsset(url: sourceURL)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1000),
            duration: CMTime(seconds: end - start, preferredTimescale: 1000)
        )

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        exportSession.outputURL = destURL
        exportSession.outputFileType = .caf
        exportSession.timeRange = timeRange

        if #available(macOS 15.0, *) {
            do {
                try await exportSession.export(to: destURL, as: .caf)
            } catch {
                print("Failed to extract audio clip: \(error)")
            }
        } else {
            await exportSession.export()
            if let error = exportSession.error {
                print("Failed to extract audio clip: \(error)")
            }
        }
    }

    // MARK: - Legacy Migration

    /// Migrate old VoicePrint data from ~/.meeting-recorder/voices/ to new People format
    private func migrateFromLegacyVoicePrints() {
        let legacyDir = URL(fileURLWithPath: Preferences.legacyVoicesPath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: legacyDir.path),
              !fm.fileExists(atPath: indexURL.path) else { return }

        guard let files = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for jsonFile in files where jsonFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: jsonFile),
                  let legacy = try? decoder.decode(LegacyVoicePrint.self, from: data) else { continue }

            let personID = legacy.id
            let personDir = peopleDir.appendingPathComponent(personID.uuidString)
            try? fm.createDirectory(at: personDir, withIntermediateDirectories: true)

            // Copy the audio sample
            let legacySampleURL = legacyDir.appendingPathComponent(legacy.sampleFilename)
            let sampleID = UUID()
            let newSampleURL = personDir.appendingPathComponent("\(sampleID.uuidString).caf")
            if fm.fileExists(atPath: legacySampleURL.path) {
                try? fm.copyItem(at: legacySampleURL, to: newSampleURL)
            }

            let sample = VoiceSample(
                id: sampleID,
                embedding: Self.normalize(legacy.embedding),
                duration: 10, // approximate, legacy didn't store duration
                sourceRecordingID: nil,
                createdAt: legacy.createdAt,
                modelVersion: nil,
                qualityScore: nil
            )

            let person = Person(
                id: personID,
                name: legacy.name,
                samples: [sample],
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                notes: nil
            )

            people.append(person)
        }

        if !people.isEmpty {
            people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            saveIndex()
            print("Migrated \(people.count) voice prints to People format")
        }
    }
}

// Legacy model for migration only
private struct LegacyVoicePrint: Codable {
    let id: UUID
    var name: String
    var embedding: [Float]
    var sampleFilename: String
    var createdAt: Date
    var updatedAt: Date
}
