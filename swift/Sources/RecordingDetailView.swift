import SwiftUI

struct RecordingDetailView: View {
    @ObservedObject var state: AppState
    let entry: RecordingEntry

    @State private var showingDeleteConfirm = false
    @State private var showingRemoveConfirm = false
    @State private var copiedTranscript = false
    @State private var editingTitle = false
    @State private var editedTitle = ""
    @State private var showNotes = false
    @State private var editedNotes = ""
    @State private var isEditingTranscript = false
    @State private var editedTranscriptText = ""

    private static var pendingNotesSave: DispatchWorkItem?
    /// Captures the most recent unsaved notes payload so `flushPendingNotesSave`
    /// can write it synchronously even after the work item is cancelled.
    private static var pendingNotesValue: (() -> Void)?
    private static func cancelNotesSave() {
        pendingNotesSave?.cancel()
        pendingNotesSave = nil
        pendingNotesValue = nil
    }
    /// Run any pending debounced notes save immediately, so the note value is
    /// persisted before the next operation (save, switch recording, etc.).
    private static func flushPendingNotesSave() {
        pendingNotesSave?.cancel()
        pendingNotesSave = nil
        pendingNotesValue?()
        pendingNotesValue = nil
    }

    private let speakerColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo, .mint, .cyan
    ]

    private var markdownURL: URL? {
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let filename = "\(entry.id)-\(slug).md"
        let url = URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                detailHeader
                Divider()

                if !state.pendingSpeakers.isEmpty {
                    SpeakerConfirmationView(state: state)
                }

                if showNotes {
                    notesPanel
                    Divider()
                }

                transcriptPanel
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, 52)
            }

            actionBar
                .padding(.bottom, 10)
        }
        .alert("Delete Audio?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                state.deleteAudioFile(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio file will be deleted. Transcript is kept.")
        }
        .alert("Remove Recording?", isPresented: $showingRemoveConfirm) {
            Button("Remove", role: .destructive) {
                state.removeRecording(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the recording and all data.")
        }
        .onChange(of: state.selectedRecordingID) { _, _ in
            // Commit any in-flight transcript edit before swapping recordings,
            // otherwise edits are silently discarded.
            if isEditingTranscript { commitTranscriptEdit() }
            // Flush any pending debounced notes save so we don't lose keystrokes.
            Self.flushPendingNotesSave()
            editingTitle = false
            isEditingTranscript = false
            editedNotes = entry.notes ?? ""
        }
        .onAppear {
            editedNotes = entry.notes ?? ""
        }
    }

    // MARK: - Header

    private var detailHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if editingTitle {
                    TextField("Title", text: $editedTitle)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit {
                            state.renameRecording(entry, to: editedTitle)
                            editingTitle = false
                        }
                        .onExitCommand { editingTitle = false }
                } else {
                    Text(entry.title)
                        .font(.title2.weight(.semibold))
                        .onTapGesture(count: 2) {
                            editedTitle = entry.title
                            editingTitle = true
                        }
                }

                HStack(spacing: 8) {
                    Text(entry.dateFormatted)
                    if entry.duration > 0 {
                        Text("·"); Text(entry.durationFormatted)
                    }
                    if state.micOnlyRecording {
                        Text("Mic only")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !state.skippedSpeakers.isEmpty {
                Button {
                    state.repromptSkippedSpeakers()
                } label: {
                    Label("\(state.skippedSpeakers.count) skipped — re-prompt", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-prompt \(state.skippedSpeakers.count) skipped speaker(s)")
            } else if state.pendingSpeakers.isEmpty {
                let unresolvedCount = state.unresolvedSpeakerCount(for: entry)
                if unresolvedCount > 0 {
                    Button {
                        state.reopenSpeakerTagging()
                    } label: {
                        Label("Tag \(unresolvedCount) speaker\(unresolvedCount == 1 ? "" : "s")", systemImage: "person.badge.clock")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Re-open speaker confirmation for this recording")
                }
            }

            HStack(spacing: 6) {
                statusPill("Transcribed", step: state.transcribeStep)
                statusPill("Saved", step: state.saveStep)
            }

            Button {
                showNotes.toggle()
                if showNotes { editedNotes = entry.notes ?? "" }
            } label: {
                Label("Notes", systemImage: showNotes ? "note.text" : "note.text.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button("Reveal audio in Finder") {
                    if let url = state.recordingStore.audioURL(for: entry) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(!entry.audioFileExists)
                Button("Reveal markdown in Finder") {
                    if let url = markdownURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(markdownURL == nil)
                Divider()
                Button("Delete audio file") { showingDeleteConfirm = true }
                Divider()
                Button("Remove entirely", role: .destructive) { showingRemoveConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func statusPill(_ label: String, step: PipelineStep) -> some View {
        HStack(spacing: 4) {
            Group {
                switch step {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running:
                    ProgressView().controlSize(.mini)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.quaternary)
                }
            }
            .symbolRenderingMode(.hierarchical)
            Text(label)
                .foregroundStyle(step == .done ? .primary : .secondary)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Notes Panel

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            TextEditor(text: $editedNotes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .frame(minHeight: 60, maxHeight: 120)
                .onChange(of: editedNotes) { _, newValue in
                    Self.cancelNotesSave()
                    let commit: () -> Void = {
                        state.updateNotes(entry, to: newValue)
                        Self.pendingNotesValue = nil
                    }
                    Self.pendingNotesValue = commit
                    let work = DispatchWorkItem(block: commit)
                    Self.pendingNotesSave = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                }
        }
    }

    // MARK: - Transcript Panel

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.transcript.isEmpty {
                    Button {
                        if isEditingTranscript {
                            commitTranscriptEdit()
                        }
                        isEditingTranscript.toggle()
                        if isEditingTranscript {
                            editedTranscriptText = state.transcript
                        }
                    } label: {
                        Label(isEditingTranscript ? "Done" : "Edit", systemImage: isEditingTranscript ? "checkmark.circle" : "pencil")
                            .foregroundStyle(isEditingTranscript ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isEditingTranscript ? "Finish editing" : "Edit transcript")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.transcript, forType: .string)
                        copiedTranscript = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTranscript = false }
                    } label: {
                        Image(systemName: copiedTranscript ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copiedTranscript ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy transcript")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if state.transcript.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    if state.transcribeStep == .running {
                        if let dl = state.modelDownloadProgress {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text(state.statusMessage.isEmpty ? "Downloading model..." : state.statusMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                ProgressView(value: dl)
                                    .progressViewStyle(.linear)
                                    .frame(width: 240)
                                Text("\(Int(dl * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                            Text(state.statusMessage.isEmpty ? "Transcribing..." : state.statusMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "text.quote")
                            .font(.title)
                            .foregroundStyle(.quaternary)
                        Text("No transcript yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEditingTranscript {
                TextEditor(text: $editedTranscriptText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(parsedSegments.enumerated()), id: \.offset) { _, seg in
                            transcriptRow(seg)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.bottom, 8)
                }
            }

            if state.recordingStore.audioURL(for: entry) != nil {
                Divider()
                playerBar
            }
        }
    }

    // MARK: - Transcript Editing

    private func commitTranscriptEdit() {
        guard editedTranscriptText != state.transcript else { return }
        state.transcript = editedTranscriptText
        if let id = state.selectedRecordingID {
            state.recordingStore.update(id: id, transcript: editedTranscriptText)
        }
        state.markDirty()
    }

    // MARK: - Transcript Parsing & Display

    private struct TranscriptSegment {
        let timestamp: String
        let speaker: String
        let text: String
    }

    private var parsedSegments: [TranscriptSegment] {
        // Format: [Speaker Name] [MM:SS]\nText\n\n[Speaker Name] [MM:SS]\nText
        let blocks = state.transcript.components(separatedBy: "\n\n")

        return blocks.compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let firstLine = lines.first?.trimmingCharacters(in: .whitespaces),
                  !firstLine.isEmpty else { return nil }

            // Try new format: [Speaker Name] [MM:SS]
            let newPattern = #"^\[(.+?)\]\s*\[(\d+:\d+)\]$"#
            if let regex = try? NSRegularExpression(pattern: newPattern),
               let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)) {
                let speaker = Range(match.range(at: 1), in: firstLine).map { String(firstLine[$0]) } ?? ""
                let ts = Range(match.range(at: 2), in: firstLine).map { String(firstLine[$0]) } ?? ""
                let text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(timestamp: ts, speaker: speaker, text: text)
            }

            // Fallback: old format [MM:SS] Speaker: text or **[MM:SS] Speaker:** text
            let oldPatterns = [
                #"^\*{0,2}\[(\d+:\d+)\]\s*(.+?):\*{0,2}\s*(.*)"#,
                #"^\[(\d+:\d+)\]\s*(.+?):\s*(.*)"#,
            ]
            for pattern in oldPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)) {
                    let ts = Range(match.range(at: 1), in: firstLine).map { String(firstLine[$0]) } ?? ""
                    let speaker = Range(match.range(at: 2), in: firstLine).map { String(firstLine[$0]) } ?? ""
                    var text = Range(match.range(at: 3), in: firstLine).map { String(firstLine[$0]) } ?? firstLine
                    text = text.replacingOccurrences(of: "**", with: "")
                    // Strip WhisperKit tokens
                    if let tokenRegex = try? NSRegularExpression(pattern: #"<\|[^|]*\|>"#) {
                        text = tokenRegex.stringByReplacingMatches(
                            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
                        ).trimmingCharacters(in: .whitespaces)
                    }
                    guard !text.isEmpty else { return nil }
                    return TranscriptSegment(timestamp: ts, speaker: speaker, text: text)
                }
            }

            // Plain text fallback
            return TranscriptSegment(timestamp: "", speaker: "", text: firstLine)
        }
    }

    private func transcriptRow(_ seg: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !seg.speaker.isEmpty {
                Text(seg.speaker.prefix(1).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(colorFor(speaker: seg.speaker)))
            }

            VStack(alignment: .leading, spacing: 2) {
                if !seg.speaker.isEmpty {
                    HStack(spacing: 6) {
                        Text(seg.speaker)
                            .font(.subheadline.weight(.medium))
                        Button {
                            seekToTimestamp(seg.timestamp)
                        } label: {
                            Text(seg.timestamp)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Play from \(seg.timestamp)")
                    }
                }
                Text(seg.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func colorFor(speaker: String) -> Color {
        let hash = abs(speaker.hashValue)
        return speakerColors[hash % speakerColors.count]
    }

    /// Seek the audio player to the given MM:SS (or H:MM:SS) timestamp and start playing.
    private func seekToTimestamp(_ timestamp: String) {
        let parts = timestamp.split(separator: ":").map(String.init)
        let seconds: Double
        switch parts.count {
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return }
            seconds = m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return }
            seconds = h * 3600 + m * 60 + s
        default:
            return
        }
        guard let url = state.recordingStore.audioURL(for: entry) else { return }
        // Load on first use so totalDuration is known. `load` leaves the player
        // ready but paused, so seek + resume plays from the desired position
        // (calling `play(url:)` would reset to 0 — wrong for tap-to-seek).
        if state.player.totalDuration <= 0 {
            state.player.load(url: url)
        }
        guard state.player.totalDuration > 0 else { return }
        let fraction = max(0, min(1, seconds / state.player.totalDuration))
        state.player.seek(to: fraction)
        state.player.resume()
    }

    // MARK: - Player Bar

    private var playerBar: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * state.player.progress), height: 4)
                }
                .frame(height: 8)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = value.location.x / geo.size.width
                    if state.player.totalDuration <= 0 {
                        if let url = state.recordingStore.audioURL(for: entry) {
                            state.player.load(url: url)
                        }
                        guard state.player.totalDuration > 0 else { return }
                    }
                    state.player.seek(to: max(0, min(1, fraction)))
                })
            }
            .frame(height: 8)

            HStack {
                Text(state.player.currentTimeFormatted)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    if state.player.isPlaying {
                        state.player.pause()
                    } else if state.player.progress > 0 && state.player.progress < 1 {
                        state.player.resume()
                    } else if let url = state.recordingStore.audioURL(for: entry) {
                        state.player.play(url: url)
                    }
                } label: {
                    Image(systemName: state.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(state.player.totalDurationFormatted)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }

            Spacer()

            Picker("Language", selection: Binding(
                get: { entry.language ?? "" },
                set: { newValue in
                    state.setLanguage(entry, to: newValue.isEmpty ? nil : newValue)
                }
            )) {
                Text("Auto").tag("")
                Text("DA").tag("da")
                Text("EN").tag("en")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .controlSize(.small)
            .help("Transcription language for this recording")

            if entry.status == "transcribed_raw" && entry.audioFileExists {
                Button {
                    Task { await state.completeDiarization() }
                } label: {
                    if state.transcribeStep == .running {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Identifying speakers...")
                        }
                    } else {
                        Label("Complete Transcription", systemImage: "person.wave.2")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.transcribeStep == .running)
            }

            Button {
                Task { await state.runTranscribe() }
            } label: {
                if state.transcribeStep == .running && entry.status != "transcribed_raw" {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Transcribing...")
                    }
                } else {
                    Label(
                        (state.transcribeStep == .done || entry.status == "transcribed_raw") ? "Re-transcribe" : "Transcribe",
                        systemImage: "waveform.badge.mic"
                    )
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.transcribeStep == .running || !entry.audioFileExists)

            Button {
                // Flush any pending debounced notes save so the markdown gets the freshest notes.
                if isEditingTranscript { commitTranscriptEdit() }
                Self.flushPendingNotesSave()
                Task { await state.runSave() }
            } label: {
                if state.saveStep == .running {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Saving...")
                    }
                } else if state.saveStep == .done {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(state.saveStep == .done ? .green : nil)
            .disabled(state.transcript.isEmpty || state.saveStep == .running)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }
}

