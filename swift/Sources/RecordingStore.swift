import Foundation
import SpeakerMatchingCore

@MainActor
class RecordingStore: ObservableObject {
    @Published var recordings: [RecordingEntry] = []

    private var pendingSaveWork: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.2

    private var indexURL: URL {
        URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent("recordings.json")
    }

    // MARK: - Load / Save

    /// Schedule a debounced save. Multiple rapid mutations coalesce into one write.
    private func scheduleSave() {
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: work)
    }

    /// Force-flush any pending debounced save immediately. Call on app quit.
    func flush() {
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        save()
    }

    func load() {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            scanForOrphanRecordings()
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recordings = try decoder.decode([RecordingEntry].self, from: data)
            scanForOrphanRecordings()
        } catch {
            print("Failed to load recordings index: \(error)")
            scanForOrphanRecordings()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(recordings)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("Failed to save recordings index: \(error)")
        }
    }

    // MARK: - CRUD

    func add(_ entry: RecordingEntry) {
        recordings.insert(entry, at: 0)
        scheduleSave()
    }

    func update(id: String, transcript: String? = nil, status: String? = nil, duration: Double? = nil, language: String?? = nil, notes: String?? = nil, rawSegmentsJSON: String?? = nil, mergedSegmentsJSON: String?? = nil) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        if let t = transcript { recordings[idx].transcript = t }
        if let s = status { recordings[idx].status = s }
        if let d = duration { recordings[idx].duration = d }
        if let l = language { recordings[idx].language = l }
        if let n = notes { recordings[idx].notes = n }
        if let r = rawSegmentsJSON { recordings[idx].rawSegmentsJSON = r }
        if let m = mergedSegmentsJSON { recordings[idx].mergedSegmentsJSON = m }
        scheduleSave()
    }

    func rename(id: String, to newTitle: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].title = newTitle
        scheduleSave()
    }

    /// Delete only audio files; keep the recording entry with transcript
    func deleteAudioFile(for entry: RecordingEntry) {
        for url in audioFileURLs(for: entry) {
            try? FileManager.default.removeItem(at: url)
        }
        // Duration is preserved so the user still sees the original length
        scheduleSave()
    }

    /// Remove the recording entirely (audio files + index entry)
    func remove(_ entry: RecordingEntry) {
        for url in audioFileURLs(for: entry) {
            try? FileManager.default.removeItem(at: url)
        }
        recordings.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func recording(for id: String) -> RecordingEntry? {
        recordings.first { $0.id == id }
    }

    func audioURL(for entry: RecordingEntry) -> URL? {
        let url = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(entry.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func audioFileURLs(for entry: RecordingEntry) -> [URL] {
        let finalURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(entry.filename)
        let stems = AudioSourceStemURLs.expectedSiblings(for: finalURL)
        return [finalURL, stems.microphoneURL, stems.systemURL]
    }

    // MARK: - Recovery

    @discardableResult
    func recoverInterruptedRecordings() -> Int {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        var recoveredCount = 0
        for i in recordings.indices where recordings[i].status == "recording" {
            let url = dir.appendingPathComponent(recordings[i].filename)
            if FileManager.default.fileExists(atPath: url.path) {
                recordings[i].duration = Self.wavDuration(url: url)
                recordings[i].status = "recorded"
                recoveredCount += 1
            }
        }
        // Recover entries that crashed mid-transcription.
        // If they have a transcript (WhisperKit finished), promote to "transcribed_raw"
        // so the diarization can resume without re-running the expensive ASR pass.
        // Otherwise reset to "recorded" so user can retry from scratch.
        for i in recordings.indices where recordings[i].status == "transcribing" {
            if recordings[i].transcript != nil {
                recordings[i].status = "transcribed_raw"
            } else {
                recordings[i].status = "recorded"
            }
            recoveredCount += 1
        }
        if recoveredCount > 0 { save() }
        return recoveredCount
    }

    // MARK: - Retention Cleanup

    func performRetentionCleanup() {
        let days = Preferences.shared.retentionDays
        guard days > 0 else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let mode = Preferences.shared.retentionMode
        let expired = recordings.filter { $0.date < cutoff }
        guard !expired.isEmpty else { return }

        let fm = FileManager.default
        for entry in expired {
            // Always delete audio files, including mic/system stems.
            for url in audioFileURLs(for: entry) {
                try? fm.removeItem(at: url)
            }

            if mode == "all" {
                // Also delete markdown (keyed by recordingID prefix) and remove from index
                let meetingsDir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
                let prefix = entry.id + "-"
                if let files = try? fm.contentsOfDirectory(at: meetingsDir, includingPropertiesForKeys: nil) {
                    for file in files where file.pathExtension == "md" && file.lastPathComponent.hasPrefix(prefix) {
                        try? fm.removeItem(at: file)
                    }
                }
                recordings.removeAll { $0.id == entry.id }
            }
        }
        save()
    }

    // MARK: - Orphan Scanning

    private func scanForOrphanRecordings() {
        let dir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        var changed = false
        let existingIDs = Set(recordings.map(\.id))
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"

        for file in files where file.pathExtension == "wav" {
            let id = file.deletingPathExtension().lastPathComponent
            if id.hasSuffix(".mic") || id.hasSuffix(".sys") { continue }
            if existingIDs.contains(id) { continue }

            let date = df.date(from: id) ?? ((try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date())
            recordings.append(RecordingEntry(
                id: id, filename: file.lastPathComponent, date: date,
                duration: Self.wavDuration(url: file), title: id,
                status: "recorded", transcript: nil
            ))
            changed = true
        }

        // Fill in missing durations
        for i in recordings.indices where recordings[i].duration == 0 {
            let url = dir.appendingPathComponent(recordings[i].filename)
            let dur = Self.wavDuration(url: url)
            if dur > 0 { recordings[i].duration = dur; changed = true }
        }

        if changed {
            recordings.sort { $0.date > $1.date }
            save()
        }
    }

    // MARK: - WAV Duration

    static func wavDuration(url: URL) -> Double {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 44), header.count >= 44 else { return 0 }
        let sampleRate = header.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        let bitsPerSample = header.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        let numChannels = header.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard sampleRate > 0, bitsPerSample > 0, numChannels > 0 else { return 0 }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let dataSize = max(0, Int(fileSize) - 44)
        let bytesPerSample = Int(bitsPerSample) / 8 * Int(numChannels)
        guard bytesPerSample > 0 else { return 0 }
        return Double(dataSize) / Double(bytesPerSample) / Double(sampleRate)
    }
}
