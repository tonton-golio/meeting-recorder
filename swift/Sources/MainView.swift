import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var recordingStore: RecordingStore
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detailArea
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            state.isWindowOpen = true
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            state.isWindowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
        .task {
            state.bootstrap()
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showPeople) {
            PeopleSheet(store: state.peopleStore, player: state.player, state: state)
        }
        .background {
            // Cmd+R: toggle recording (window-level shortcut)
            Button("") {
                if state.isRecording { state.stopRecording() }
                else { state.startRecording() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .hidden()
        }
        .alert("Microphone Access Required", isPresented: $state.showMicPermissionAlert) {
            Button("Open System Settings") { state.openMicrophoneSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Meeting Recorder needs microphone access to record audio. Please enable it in System Settings > Privacy & Security > Microphone.")
        }
        .alert(
            "Voice doesn't match \(state.pendingContamination?.person.name ?? "this person")",
            isPresented: Binding(
                get: { state.pendingContamination != nil },
                set: { if !$0 { state.pendingContamination = nil } }
            )
        ) {
            Button("Add Anyway", role: .destructive) {
                if let c = state.pendingContamination {
                    state.forceAddSpeakerToPerson(c.speaker, person: c.person)
                }
            }
            Button("Cancel", role: .cancel) {
                state.pendingContamination = nil
            }
        } message: {
            if let c = state.pendingContamination {
                Text("This clip only matches \(c.person.name)'s existing samples at \(c.percentageString). Adding it may degrade future recognition. Are you sure?")
            } else {
                Text("")
            }
        }
        .alert("Low Disk Space", isPresented: $state.showDiskSpaceAlert) {
            Button("Continue Anyway") { state.diskSpaceAlertContinue() }
            Button("Cancel", role: .cancel) { state.diskSpaceAlertCancel() }
        } message: {
            Text(state.diskSpaceWarning ?? "Disk space is low.")
        }
        .alert("Recording Recovered", isPresented: Binding(
            get: { state.recoveredCount > 0 },
            set: { if !$0 { state.recoveredCount = 0 } }
        )) {
            Button("OK") { state.recoveredCount = 0 }
        } message: {
            Text("\(state.recoveredCount) recording\(state.recoveredCount == 1 ? " was" : "s were") interrupted and may need re-transcription.")
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Record button — system .borderedProminent with red tint
            Button {
                if state.isRecording { state.stopRecording() }
                else { state.startRecording() }
            } label: {
                Label(
                    state.isRecording ? "Stop  \(state.elapsedString)" : "Record",
                    systemImage: state.isRecording ? "stop.circle.fill" : "record.circle.fill"
                )
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Recordings list
            List(selection: Binding(
                get: { state.selectedRecordingID },
                set: { id in
                    if let id, let rec = recordingStore.recordings.first(where: { $0.id == id }) {
                        state.selectRecording(rec)
                    }
                }
            )) {
                if !filteredRecordings.isEmpty {
                    ForEach(groupedRecordings, id: \.0) { group, entries in
                        Section(group) {
                            ForEach(entries) { entry in
                                sidebarRow(entry)
                                    .tag(entry.id)
                                    .contextMenu {
                                        Button("Rename") {
                                            // Trigger rename by selecting and using detail header
                                            state.selectRecording(entry)
                                        }
                                        Button("Reveal in Finder") {
                                            revealInFinder(entry)
                                        }
                                        Divider()
                                        Button("Delete audio file") {
                                            state.deleteAudioFile(entry)
                                        }
                                        .disabled(!entry.audioFileExists)
                                        Divider()
                                        Button("Delete recording", role: .destructive) {
                                            state.removeRecording(entry)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search recordings")

            // Footer
            Divider()
            HStack(spacing: 16) {
                Button { state.showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button { state.showPeople = true } label: {
                    Image(systemName: "person.wave.2")
                        .foregroundStyle(.secondary)
                        .overlay(alignment: .topTrailing) {
                            if state.peopleStore.hasHealthIssues {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(state.peopleStore.hasHealthIssues
                      ? "People — \(state.peopleStore.healthIssues.count) issue\(state.peopleStore.healthIssues.count == 1 ? "" : "s")"
                      : "People")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Sidebar Row

    private func sidebarRow(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 8) {
            statusDot(entry)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.title)
                        .font(.body)
                        .lineLimit(1)
                    if matchedInTranscript(entry) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text(entry.dateFormatted)
                    if entry.duration > 0 { Text("·"); Text(entry.durationFormatted) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ entry: RecordingEntry) -> some View {
        switch entry.status {
        case "saved":
            Circle().fill(.green).frame(width: 8, height: 8)
        case "transcribed":
            Circle().fill(.blue).frame(width: 8, height: 8)
        case "transcribed_raw":
            Circle().fill(.yellow).frame(width: 8, height: 8)
        case "transcribing":
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case "recording":
            Circle().fill(.red).frame(width: 8, height: 8)
        default:
            Circle().fill(.quaternary).frame(width: 8, height: 8)
        }
    }

    // MARK: - Detail Area

    @ViewBuilder
    private var detailArea: some View {
        if state.isRecording {
            RecordingInProgressView(state: state)
        } else if let entry = state.selectedRecording {
            RecordingDetailView(state: state, entry: entry)
        } else {
            emptyState
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("No recording selected")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Select a recording or press Record to start")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filtering & Grouping

    private var filteredRecordings: [RecordingEntry] {
        if searchText.isEmpty { return recordingStore.recordings }
        let q = searchText.lowercased()
        return recordingStore.recordings.filter {
            $0.title.lowercased().contains(q)
            || $0.dateFormatted.lowercased().contains(q)
            || ($0.transcript?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    /// Returns true when the search matched inside the transcript (not in the title or date).
    private func matchedInTranscript(_ entry: RecordingEntry) -> Bool {
        guard !searchText.isEmpty else { return false }
        let q = searchText.lowercased()
        if entry.title.lowercased().contains(q) || entry.dateFormatted.lowercased().contains(q) {
            return false
        }
        return entry.transcript?.localizedCaseInsensitiveContains(searchText) == true
    }

    // MARK: - Reveal in Finder

    private func revealInFinder(_ entry: RecordingEntry) {
        if let audioURL = recordingStore.audioURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([audioURL])
        } else if let mdURL = markdownURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([mdURL])
        }
    }

    private func markdownURL(for entry: RecordingEntry) -> URL? {
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let filename = "\(entry.id)-\(slug).md"
        let url = URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var groupedRecordings: [(String, [RecordingEntry])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!

        var groups: [(String, [RecordingEntry])] = []
        var t: [RecordingEntry] = [], y: [RecordingEntry] = [], w: [RecordingEntry] = [], o: [RecordingEntry] = []

        for rec in filteredRecordings {
            let d = cal.startOfDay(for: rec.date)
            if d >= today { t.append(rec) }
            else if d >= yesterday { y.append(rec) }
            else if d >= weekAgo { w.append(rec) }
            else { o.append(rec) }
        }

        if !t.isEmpty { groups.append(("Today", t)) }
        if !y.isEmpty { groups.append(("Yesterday", y)) }
        if !w.isEmpty { groups.append(("This Week", w)) }
        if !o.isEmpty { groups.append(("Older", o)) }
        return groups
    }
}
