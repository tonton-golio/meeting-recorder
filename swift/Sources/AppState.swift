import AVFoundation
import SwiftUI
import UserNotifications
import WhisperKit

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false

    // Recording
    @Published var recorder = AudioRecorder()
    @Published var player = AudioPlayer()
    @Published var elapsedString = "00:00"
    @Published var elapsedSeconds: TimeInterval = 0
    private var displayTimer: Timer?

    // Pipeline
    @Published var transcript = ""
    @Published var transcribeStep: PipelineStep = .pending
    @Published var saveStep: PipelineStep = .pending
    @Published var statusMessage = ""
    @Published var recordingDuration: TimeInterval = 0
    /// Model download progress 0.0–1.0. Nil when no download is active.
    @Published var modelDownloadProgress: Double? = nil
    /// Latched true when a recording was completed without system audio capture.
    /// Survives into the detail view so "Mic only" can be shown in the header.
    @Published var micOnlyRecording = false

    // Post-transcription: all speakers pending confirmation
    @Published var pendingSpeakers: [DetectedSpeaker] = []
    @Published var skippedSpeakers: [DetectedSpeaker] = []

    // Surfaced when a speaker is assigned to a person whose existing samples
    // are very dissimilar — catches mis-attribution before we corrupt the
    // person's voice profile.
    @Published var pendingContamination: ContaminationWarning?

    // Selection
    @Published var selectedRecordingID: String?

    // Recovery
    @Published var recoveredCount = 0

    // Window
    @Published var isWindowOpen = false
    @Published var showSettings = false
    @Published var showPeople = false
    @Published var showOnboarding = false
    @Published var showMicPermissionAlert = false
    @Published var diskSpaceWarning: String?
    @Published var showDiskSpaceAlert = false
    private var diskSpaceContinuation: CheckedContinuation<Bool, Never>?

    // Stores & Services
    let recordingStore = RecordingStore()
    let peopleStore = PeopleStore()
    let transcriptionService = TranscriptionService()

    var selectedRecording: RecordingEntry? {
        guard let id = selectedRecordingID else { return nil }
        return recordingStore.recording(for: id)
    }

    // Global hotkey
    private var globalHotkeyMonitor: Any?

    // MARK: - Initialization

    func bootstrap() {
        recordingStore.load()
        recoveredCount = recordingStore.recoverInterruptedRecordings()
        peopleStore.loadAll()
        recordingStore.performRetentionCleanup()
        requestNotificationPermission()
        setupGlobalHotkey()

        if !Preferences.shared.onboardingCompleted {
            showOnboarding = true
        }
    }

    /// Register Ctrl+Opt+R as a system-wide hotkey to toggle recording from any app.
    private func setupGlobalHotkey() {
        let expectedKeyCode = Preferences.shared.hotkeyKeyCode
        let expectedModifiers = NSEvent.ModifierFlags(rawValue: Preferences.shared.hotkeyModifiers)
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let pressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == expectedKeyCode, pressed.contains(expectedModifiers) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isRecording {
                    self.stopRecording()
                } else {
                    self.startRecording()
                }
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Disk Space Pre-flight

    /// Check available disk space at `path`. Returns bytes available, or nil on error.
    private func availableBytes(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    /// Check disk space before recording. Returns true if OK to proceed (enough space or user chose to continue).
    func checkDiskSpaceForRecording() async -> Bool {
        let path = Preferences.shared.recordingsPath
        if let bytes = availableBytes(at: path), bytes < 500_000_000 {
            let mbFree = bytes / 1_000_000
            diskSpaceWarning = "Only \(mbFree) MB free on the recordings disk. Recording may fail if disk fills up."
            return await presentDiskSpaceAlert()
        }
        return true
    }

    /// Check disk space before model download. Returns true if OK to proceed.
    func checkDiskSpaceForModelDownload() async -> Bool {
        let path = NSHomeDirectory()
        if let bytes = availableBytes(at: path), bytes < 4_000_000_000 {
            let gbFree = Double(bytes) / 1_000_000_000
            diskSpaceWarning = String(format: "Only %.1f GB free. Model download may require up to 3 GB.", gbFree)
            return await presentDiskSpaceAlert()
        }
        return true
    }

    /// Presents the disk-space alert and awaits the user's choice.
    /// Resolves any in-flight continuation first to avoid leaks on rapid re-entry.
    private func presentDiskSpaceAlert() async -> Bool {
        // If a prior alert is still in-flight, cancel it cleanly (resume with false)
        // before presenting a new one.
        if let pending = diskSpaceContinuation {
            diskSpaceContinuation = nil
            pending.resume(returning: false)
        }
        showDiskSpaceAlert = true
        return await withCheckedContinuation { continuation in
            diskSpaceContinuation = continuation
        }
    }

    func diskSpaceAlertContinue() {
        showDiskSpaceAlert = false
        diskSpaceContinuation?.resume(returning: true)
        diskSpaceContinuation = nil
    }

    func diskSpaceAlertCancel() {
        showDiskSpaceAlert = false
        diskSpaceContinuation?.resume(returning: false)
        diskSpaceContinuation = nil
    }

    // MARK: - Recording Lifecycle

    func startRecording() {
        // Microphone permission pre-flight
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.startRecordingAfterPermission()
                    } else {
                        self?.showMicPermissionAlert = true
                    }
                }
            }
            return
        case .denied, .restricted:
            showMicPermissionAlert = true
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        startRecordingAfterPermission()
    }

    private func startRecordingAfterPermission() {
        Task {
            let ok = await checkDiskSpaceForRecording()
            guard ok else { return }
            beginRecording()
        }
    }

    private func beginRecording() {
        transcript = ""
        pendingSpeakers = []
        skippedSpeakers = []
        transcribeStep = .pending
        saveStep = .pending
        statusMessage = ""
        micOnlyRecording = false

        do {
            try recorder.start()
            isRecording = true
            elapsedString = "00:00"
            elapsedSeconds = 0
            startDisplayTimer()

            let title = "Recording \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            let entry = RecordingEntry(
                id: recorder.recordingID ?? "",
                filename: (recorder.recordingID ?? "") + ".wav",
                date: Date(),
                duration: 0,
                title: title,
                status: "recording",
                transcript: nil
            )
            recordingStore.add(entry)
            selectedRecordingID = entry.id
        } catch {
            statusMessage = "Recording error: \(error.localizedDescription)"
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func stopRecording() {
        Task { await stopRecordingAndWait(autoTranscribe: Preferences.shared.autoTranscribe) }
    }

    /// Stop recording and await final WAV write. Safe to call from quit handlers.
    /// When `autoTranscribe` is false, the transcribe chain is skipped (used on app quit).
    func stopRecordingAndWait(autoTranscribe: Bool = false) async {
        stopDisplayTimer()
        isRecording = false

        do {
            let result = try await recorder.stop()
            recordingDuration = result.duration
            recordingStore.update(id: result.id, status: "recorded", duration: result.duration)
            selectedRecordingID = result.id

            // Latch mic-only flag so RecordingDetailView can show "Mic only" tag
            if recorder.systemAudioWarning != nil && Preferences.shared.captureSystemAudio {
                micOnlyRecording = true
            }

            if autoTranscribe {
                sendNotification(title: "Meeting Recorder", body: "Recording stopped. Transcribing...")
                await runTranscribe()
            }
        } catch {
            statusMessage = "Stop error: \(error.localizedDescription)"
            NSLog("[AppState] stopRecording error: \(error)")
        }
    }

    // MARK: - Display Timer

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let secs = self.recorder.elapsed
                self.elapsedSeconds = secs
                self.elapsedString = Self.formatElapsed(secs)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Format elapsed seconds as MM:SS, or H:MM:SS past 1h.
    static func formatElapsed(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: - Selection

    func selectRecording(_ entry: RecordingEntry) {
        player.stop()
        selectedRecordingID = entry.id
        transcript = entry.transcript ?? ""
        recordingDuration = entry.duration
        // transcribed_raw: WhisperKit done but diarization pending — show as "partially done"
        if entry.status == "transcribed_raw" {
            transcribeStep = .pending
        } else {
            transcribeStep = entry.transcript != nil ? .done : .pending
        }
        saveStep = entry.status == "saved" ? .done : .pending
        statusMessage = entry.status == "transcribed_raw" ? "Diarization pending — click Complete Transcription" : ""
        pendingSpeakers = []
        skippedSpeakers = []
    }

    func renameRecording(_ entry: RecordingEntry, to newTitle: String) {
        recordingStore.rename(id: entry.id, to: newTitle)
        markDirty()
    }

    /// Set transcription language for a specific recording. Pass nil to clear (use global default).
    func setLanguage(_ entry: RecordingEntry, to code: String?) {
        recordingStore.update(id: entry.id, language: .some(code))
    }

    // MARK: - Deletion

    func deleteAudioFile(_ entry: RecordingEntry) {
        player.stop()
        recordingStore.deleteAudioFile(for: entry)
    }

    func removeRecording(_ entry: RecordingEntry) {
        player.stop()
        recordingStore.remove(entry)
        if selectedRecordingID == entry.id { selectedRecordingID = nil }
    }

    // MARK: - Pipeline

    /// Guard against concurrent transcriptions if the user taps Re-transcribe mid-run.
    private var isTranscribing = false

    func runTranscribe() async {
        guard !isTranscribing else { return }
        guard let rec = selectedRecording else { return }
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            statusMessage = "Audio file not found"
            return
        }

        let ok = await checkDiskSpaceForModelDownload()
        guard ok else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        transcribeStep = .running
        statusMessage = "Loading models..."
        modelDownloadProgress = nil
        skippedSpeakers = []
        recordingStore.update(id: rec.id, status: "transcribing")

        do {
            let progressCb: (String) -> Void = { [weak self] progress in
                Task { @MainActor in self?.statusMessage = progress }
            }
            let downloadCb: (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    self?.modelDownloadProgress = fraction >= 1.0 ? nil : fraction
                }
            }

            // Phase 1: WhisperKit ASR (the expensive step)
            let rawResult = try await transcriptionService.transcribeAudio(
                audioURL: audioURL,
                languageOverride: rec.language,
                progressCallback: progressCb,
                downloadProgress: downloadCb
            )

            // Checkpoint: save raw transcript + serialized segments so a crash
            // during diarization doesn't lose the expensive WhisperKit output.
            let rawText = rawResult.rawText
            let segmentsJSON: String? = {
                let encoder = JSONEncoder()
                guard let data = try? encoder.encode(rawResult.segments) else { return nil }
                return String(data: data, encoding: .utf8)
            }()
            recordingStore.update(
                id: rec.id,
                transcript: rawText,
                status: "transcribed_raw",
                rawSegmentsJSON: .some(segmentsJSON)
            )

            modelDownloadProgress = nil

            // Phase 2: Diarization + speaker matching
            let result = try await transcriptionService.diarizeAndMatch(
                audioURL: audioURL,
                whisperSegments: rawResult.segments,
                peopleStore: peopleStore,
                progressCallback: progressCb
            )

            transcript = result.transcript
            transcribeStep = .done
            statusMessage = ""
            pendingSpeakers = result.detectedSpeakers
            recordingStore.update(id: rec.id, transcript: result.transcript, status: "transcribed", rawSegmentsJSON: .some(nil))
            persistUnresolvedSpeakers(for: rec.id)

            // Auto-save only if no speakers need confirmation
            if Preferences.shared.autoSave && pendingSpeakers.isEmpty {
                await runSave()
            }
        } catch {
            transcribeStep = .failed
            statusMessage = error.localizedDescription
            modelDownloadProgress = nil
            // If we have a raw transcript (Phase 1 succeeded), keep it as transcribed_raw
            if let current = recordingStore.recording(for: rec.id), current.status == "transcribed_raw" {
                // Don't regress — keep the checkpoint
            } else {
                recordingStore.update(id: rec.id, status: "recorded")
            }
            NSLog("[AppState] Transcription FAILED: \(error)")
        }
    }

    /// Resume diarization for a recording that completed WhisperKit but crashed before
    /// diarization finished. Deserializes the stored segments and runs only Phase 2.
    func completeDiarization() async {
        guard !isTranscribing else { return }
        guard let rec = selectedRecording else { return }
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            statusMessage = "Audio file not found — cannot complete diarization"
            return
        }
        guard let json = rec.rawSegmentsJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([TranscriptionSegment].self, from: data) else {
            statusMessage = "Stored segments not found — re-transcribe instead"
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        transcribeStep = .running
        statusMessage = "Identifying speakers..."
        recordingStore.update(id: rec.id, status: "transcribing")

        do {
            let result = try await transcriptionService.diarizeAndMatch(
                audioURL: audioURL,
                whisperSegments: segments,
                peopleStore: peopleStore,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in self?.statusMessage = progress }
                }
            )

            transcript = result.transcript
            transcribeStep = .done
            statusMessage = ""
            pendingSpeakers = result.detectedSpeakers
            recordingStore.update(id: rec.id, transcript: result.transcript, status: "transcribed", rawSegmentsJSON: .some(nil))
            persistUnresolvedSpeakers(for: rec.id)

            if Preferences.shared.autoSave && pendingSpeakers.isEmpty {
                await runSave()
            }
        } catch {
            transcribeStep = .failed
            statusMessage = error.localizedDescription
            recordingStore.update(id: rec.id, status: "transcribed_raw")
            NSLog("[AppState] Diarization FAILED: \(error)")
        }
    }

    func runSave() async {
        guard let rec = selectedRecording else { return }
        saveStep = .running

        do {
            let speakers = MarkdownWriter.extractSpeakers(from: transcript)
            let path = try MarkdownWriter.save(
                title: rec.title,
                transcript: transcript,
                recordingID: rec.id,
                duration: recordingDuration,
                speakers: speakers,
                notes: rec.notes
            )
            saveStep = .done
            recordingStore.update(id: rec.id, status: "saved")
            sendNotification(title: "Meeting Recorder", body: "Saved: \(URL(fileURLWithPath: path).lastPathComponent)")
        } catch {
            saveStep = .failed
            statusMessage = error.localizedDescription
        }
    }

    func reprocess() async {
        transcribeStep = .pending
        saveStep = .pending
        await runTranscribe()
    }

    // MARK: - Speaker Confirmation

    /// Confirm a high-confidence match. Always adds a voice sample to improve future recognition.
    func confirmSpeaker(_ speaker: DetectedSpeaker) {
        guard let rec = selectedRecording,
              let person = speaker.matchedPerson else { return }
        let audioURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(rec.filename)

        Task {
            await peopleStore.addSample(
                to: person,
                audioURL: audioURL,
                startTime: speaker.sampleStartTime,
                endTime: speaker.sampleEndTime,
                embedding: speaker.embedding,
                qualityScore: speaker.sampleQuality,
                captureSource: speaker.captureSource
            )
        }

        // Name is already correct in transcript
        pendingSpeakers.removeAll { $0.id == speaker.id }
        persistUnresolvedSpeakers(for: rec.id)
        checkAutoSave()
    }

    /// Confirm all high-confidence matches in one click.
    func confirmAllMatched() {
        let matched = pendingSpeakers.filter { $0.isHighConfidence }
        for speaker in matched {
            confirmSpeaker(speaker)
        }
    }

    /// Assign speaker to an existing person (correction or low-confidence pick).
    /// If the clip doesn't sound like this person's existing samples, surfaces
    /// a contamination warning so the user can confirm before we write it.
    func addSpeakerToExistingPerson(_ speaker: DetectedSpeaker, person: Person) {
        if let score = peopleStore.similarityToExistingSamples(embedding: speaker.embedding, person: person),
           score < PeopleStore.contaminationThreshold {
            pendingContamination = ContaminationWarning(
                speaker: speaker,
                person: person,
                similarity: score
            )
            return
        }
        commitSpeakerToPerson(speaker, person: person)
    }

    /// Called after the user explicitly confirms a low-similarity assignment.
    func forceAddSpeakerToPerson(_ speaker: DetectedSpeaker, person: Person) {
        commitSpeakerToPerson(speaker, person: person)
        pendingContamination = nil
    }

    private func commitSpeakerToPerson(_ speaker: DetectedSpeaker, person: Person) {
        guard let rec = selectedRecording else { return }
        let audioURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(rec.filename)

        Task {
            await peopleStore.addSample(
                to: person,
                audioURL: audioURL,
                startTime: speaker.sampleStartTime,
                endTime: speaker.sampleEndTime,
                embedding: speaker.embedding,
                qualityScore: speaker.sampleQuality,
                captureSource: speaker.captureSource
            )
        }

        // Update transcript with the person's name
        transcript = transcript.replacingOccurrences(
            of: "[\(speaker.assignedName)]",
            with: "[\(person.name)]"
        )
        if let id = selectedRecordingID {
            recordingStore.update(id: id, transcript: transcript)
        }
        pendingSpeakers.removeAll { $0.id == speaker.id }
        persistUnresolvedSpeakers(for: rec.id)
        markDirty()
        checkAutoSave()
    }

    /// Create a new person from this speaker. Adds a voice sample.
    func saveSpeakerAsNewPerson(_ speaker: DetectedSpeaker, name: String) {
        guard let rec = selectedRecording else { return }
        let audioURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(rec.filename)

        Task {
            let _ = await peopleStore.createPerson(
                name: name,
                audioURL: audioURL,
                startTime: speaker.sampleStartTime,
                endTime: speaker.sampleEndTime,
                embedding: speaker.embedding,
                qualityScore: speaker.sampleQuality,
                captureSource: speaker.captureSource
            )
        }

        // Update transcript with the real name
        transcript = transcript.replacingOccurrences(
            of: "[\(speaker.assignedName)]",
            with: "[\(name)]"
        )
        if let id = selectedRecordingID {
            recordingStore.update(id: id, transcript: transcript)
        }
        pendingSpeakers.removeAll { $0.id == speaker.id }
        persistUnresolvedSpeakers(for: rec.id)
        markDirty()
        checkAutoSave()
    }

    func skipSpeaker(_ speaker: DetectedSpeaker) {
        pendingSpeakers.removeAll { $0.id == speaker.id }
        skippedSpeakers.append(speaker)
        if let id = selectedRecordingID {
            persistUnresolvedSpeakers(for: id)
        }
        checkAutoSave()
    }

    /// Move all skipped speakers back into pendingSpeakers for re-prompting.
    func repromptSkippedSpeakers() {
        pendingSpeakers.append(contentsOf: skippedSpeakers)
        skippedSpeakers.removeAll()
    }

    // MARK: - Speaker Persistence (re-open tagging later)

    /// Persist the current pending+skipped speaker list onto the selected
    /// recording's `unresolvedSpeakersJSON`, so the user can re-open the
    /// confirmation UI from the detail view after navigating away.
    /// Resolved speakers (already removed from both lists) are not persisted.
    private func persistUnresolvedSpeakers(for recordingID: String) {
        let unresolved = pendingSpeakers + skippedSpeakers
        let encoded: String? = {
            guard !unresolved.isEmpty else { return nil }
            let snapshot = unresolved.map(PersistedSpeaker.init(from:))
            guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        recordingStore.update(id: recordingID, unresolvedSpeakersJSON: .some(encoded))
    }

    /// Re-open the speaker confirmation UI for the selected recording, using
    /// the persisted speaker snapshot. Recommendations and auto-matches are
    /// recomputed against the current PeopleStore so newly added people are
    /// considered.
    func reopenSpeakerTagging() {
        guard let rec = selectedRecording,
              let json = rec.unresolvedSpeakersJSON,
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode([PersistedSpeaker].self, from: data),
              !snapshot.isEmpty else {
            return
        }

        let autoThreshold = Preferences.shared.autoMatchThreshold
        let recommendThreshold = Preferences.shared.recommendThreshold

        let restored: [DetectedSpeaker] = snapshot.map { persisted in
            let result = peopleStore.matchWithRecommendations(
                embedding: persisted.embedding,
                source: persisted.captureSource,
                autoThreshold: autoThreshold,
                recommendThreshold: recommendThreshold
            )
            let matchScore: Float? = result.match.map { person in
                peopleStore.bestSimilarity(
                    embedding: persisted.embedding,
                    source: persisted.captureSource,
                    to: person
                )
            }
            return DetectedSpeaker(
                label: persisted.label,
                embedding: persisted.embedding,
                matchedPerson: result.match,
                matchScore: matchScore,
                assignedName: persisted.assignedName,
                sampleStartTime: persisted.sampleStartTime,
                sampleEndTime: persisted.sampleEndTime,
                sampleQuality: persisted.sampleQuality,
                captureSource: persisted.captureSource,
                recommendations: result.recommendations
            )
        }

        pendingSpeakers = restored
        skippedSpeakers = []
    }

    /// Number of unresolved (still-pending or skipped) speakers persisted on
    /// this recording. Drives whether the "Tag speakers" button is shown.
    func unresolvedSpeakerCount(for entry: RecordingEntry) -> Int {
        guard let json = entry.unresolvedSpeakersJSON,
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode([PersistedSpeaker].self, from: data) else {
            return 0
        }
        return snapshot.count
    }

    private func checkAutoSave() {
        guard let rec = selectedRecording else { return }
        if Preferences.shared.autoSave && pendingSpeakers.isEmpty {
            Task { await runSave() }
        }
    }

    // MARK: - Dirty Tracking

    /// Reset saveStep to .pending when the user modifies content after a save.
    func markDirty() {
        if saveStep == .done { saveStep = .pending }
    }

    /// Update notes for the selected recording with debounced persistence.
    func updateNotes(_ entry: RecordingEntry, to notes: String) {
        let value: String? = notes.isEmpty ? nil : notes
        recordingStore.update(id: entry.id, notes: .some(value))
        markDirty()
    }

    // MARK: - Helpers

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

}
