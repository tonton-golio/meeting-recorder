import AVFoundation
import SpeakerMatchingCore
import SwiftUI

struct PeopleSheet: View {
    @ObservedObject var store: PeopleStore
    @ObservedObject var player: AudioPlayer
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPersonID: UUID?
    @State private var showDeleteConfirm = false
    @State private var toDelete: Person?
    @State private var busyMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            healthBanner

            Divider()

            if store.people.isEmpty {
                emptyState
            } else {
                HSplitView {
                    peopleList
                        .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)

                    if let personID = selectedPersonID,
                       let person = store.people.first(where: { $0.id == personID }) {
                        PersonDetailView(
                            person: person,
                            store: store,
                            player: player,
                            state: state,
                            onDelete: {
                                toDelete = person
                                showDeleteConfirm = true
                            },
                            busyMessage: $busyMessage
                        )
                        .frame(minWidth: 420)
                    } else {
                        VStack {
                            Spacer()
                            Text("Select a person")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 860, minHeight: 560, idealHeight: 620)
        .alert("Delete Person?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let person = toDelete {
                    player.stop()
                    if selectedPersonID == person.id { selectedPersonID = nil }
                    store.delete(person)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the person and all voice samples.")
        }
        .overlay {
            if let msg = busyMessage {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(msg).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("People")
                .font(.headline)

            Spacer()

            if store.staleSampleCount > 0 {
                Text("\(store.staleSampleCount) stale")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .help("Samples embedded with a previous model version")
            }

            Text("\(store.people.count) saved")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Health Banner

    @ViewBuilder
    private var healthBanner: some View {
        let issues = store.healthIssues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "\(issues.count) issue\(issues.count == 1 ? "" : "s") found",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)

                ForEach(issues) { issue in
                    HStack(spacing: 6) {
                        Image(systemName: issue.iconName)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .symbolRenderingMode(.hierarchical)
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    // MARK: - People List

    private var peopleList: some View {
        List(selection: $selectedPersonID) {
            ForEach(store.people) { person in
                personRow(person)
                    .tag(person.id)
            }
        }
        .listStyle(.sidebar)
    }

    private func personRow(_ person: Person) -> some View {
        HStack(spacing: 10) {
            AvatarCircle(name: person.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(person.sampleCount) sample\(person.sampleCount == 1 ? "" : "s")")
                    Text("·")
                    Text(Self.compactDuration(person.totalDuration))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.wave.2")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(.secondary.opacity(0.3))
            Text("No saved people yet")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("People are saved when you name speakers\nafter a recording is transcribed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Helpers

    fileprivate static func compactDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 60 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s)s"
    }
}

// MARK: - Person Detail View

struct PersonDetailView: View {
    let person: Person
    @ObservedObject var store: PeopleStore
    @ObservedObject var player: AudioPlayer
    @ObservedObject var state: AppState
    let onDelete: () -> Void
    @Binding var busyMessage: String?

    @State private var editingName = false
    @State private var editedName = ""
    @State private var playingSampleID: UUID?
    @State private var showDeleteSampleConfirm = false
    @State private var sampleToDelete: VoiceSample?

    @State private var showLiveRecorder = false
    @State private var showMergePicker = false
    @State private var showSplitPicker = false

    private var intraSimilarityAvg: Float? {
        let embs = person.samples.map(\.embedding).filter { !$0.isEmpty }
        guard embs.count >= 2 else { return nil }
        var total: Float = 0
        var n = 0
        for i in 0..<embs.count {
            for j in (i + 1)..<embs.count {
                total += PeopleStore.cosineSimilarity(embs[i], embs[j])
                n += 1
            }
        }
        return n > 0 ? total / Float(n) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 14) {
                AvatarCircle(name: person.name, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    if editingName {
                        TextField("Name", text: $editedName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 17, weight: .semibold))
                            .onSubmit {
                                store.rename(person, to: editedName)
                                editingName = false
                            }
                            .onExitCommand { editingName = false }
                    } else {
                        HStack(spacing: 6) {
                            Text(person.name)
                                .font(.system(size: 17, weight: .semibold))
                            Button {
                                editedName = person.name
                                editingName = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 10) {
                        statBadge(label: "Samples", value: "\(person.sampleCount)")
                        statBadge(label: "Voice", value: PeopleSheet.compactDuration(person.totalDuration))
                        if let avg = intraSimilarityAvg {
                            statBadge(
                                label: "Consistency",
                                value: "\(Int(avg * 100))%",
                                tint: consistencyColor(avg)
                            )
                        }
                        let stale = person.samples.filter { ($0.modelVersion ?? "") != PeopleStore.currentEmbeddingModelVersion }.count
                        if stale > 0 {
                            statBadge(label: "Stale", value: "\(stale)", tint: .orange)
                        }
                    }

                    Text("Last heard \(person.lastSampleDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            // Action bar
            HStack(spacing: 8) {
                Button {
                    showLiveRecorder = true
                } label: {
                    Label("Record Sample", systemImage: "mic.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    Task { await recomputeEmbeddings() }
                } label: {
                    Label("Re-compute", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-extract embeddings for this person's samples using the current model")

                Button {
                    showMergePicker = true
                } label: {
                    Label("Merge…", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.people.count < 2)

                Button {
                    showSplitPicker = true
                } label: {
                    Label("Split…", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(person.sampleCount < 2)

                Spacer()

                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete Person", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Voice samples
            HStack {
                Text("Voice Samples")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(person.sampleCount) · \(PeopleSheet.compactDuration(person.totalDuration))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if person.samples.isEmpty {
                Text("No voice samples")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(person.samples) { sample in
                            SampleCard(
                                sample: sample,
                                url: store.sampleURL(for: sample, person: person),
                                isPlaying: playingSampleID == sample.id && player.isPlaying,
                                isStale: (sample.modelVersion ?? "") != PeopleStore.currentEmbeddingModelVersion,
                                onPlayToggle: {
                                    if playingSampleID == sample.id && player.isPlaying {
                                        player.stop()
                                        playingSampleID = nil
                                    } else {
                                        let url = store.sampleURL(for: sample, person: person)
                                        if FileManager.default.fileExists(atPath: url.path) {
                                            player.stop()
                                            player.play(url: url)
                                            playingSampleID = sample.id
                                        }
                                    }
                                },
                                onDelete: {
                                    sampleToDelete = sample
                                    showDeleteSampleConfirm = true
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }

            Spacer()
        }
        .sheet(isPresented: $showLiveRecorder) {
            LiveSampleRecorderView(
                personName: person.name,
                onSaved: { url, duration, embedding, quality in
                    store.addSampleFromFile(
                        to: person,
                        existingClipURL: url,
                        duration: duration,
                        embedding: embedding,
                        qualityScore: quality,
                        captureSource: .microphone
                    )
                },
                transcriptionService: state.transcriptionService
            )
        }
        .sheet(isPresented: $showMergePicker) {
            MergePickerView(
                person: person,
                store: store,
                onMerge: { other in
                    store.merge(other, into: person)
                }
            )
        }
        .sheet(isPresented: $showSplitPicker) {
            SplitPickerView(
                person: person,
                store: store
            )
        }
        .alert("Delete Sample?", isPresented: $showDeleteSampleConfirm) {
            Button("Delete", role: .destructive) {
                if let sample = sampleToDelete {
                    player.stop()
                    store.removeSample(sample, from: person)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This voice sample will be permanently deleted.")
        }
    }

    @MainActor
    private func recomputeEmbeddings() async {
        busyMessage = "Loading diarizer…"
        defer { busyMessage = nil }
        do {
            let dia = try await state.transcriptionService.prepareDiarizer()
            busyMessage = "Re-embedding \(person.sampleCount) sample\(person.sampleCount == 1 ? "" : "s")…"
            for sample in person.samples {
                await store.reembedSample(sample, for: person, using: dia)
            }
        } catch {
            busyMessage = "Re-embed failed: \(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: - Small helpers

    private func statBadge(label: String, value: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func consistencyColor(_ avg: Float) -> Color {
        if avg >= 0.55 { return .green }
        if avg >= 0.35 { return .orange }
        return .red
    }
}

// MARK: - Sample Card

struct SampleCard: View {
    let sample: VoiceSample
    let url: URL
    let isPlaying: Bool
    let isStale: Bool
    let onPlayToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlayToggle) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(isPlaying ? .red : .accentColor)
            }
            .buttonStyle(.plain)

            WaveformView(url: url)
                .frame(height: 30)
                .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Text(durationString)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                    if let q = sample.qualityScore {
                        Text("q\(String(format: "%.1f", q))")
                            .font(.system(size: 9))
                            .foregroundStyle(qualityColor(q))
                    }
                    if let source = sample.captureSource, source != .unknown {
                        Text(source.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if isStale {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Embedding is from a previous model — re-compute to refresh")
                    }
                }
                Text(sample.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if let src = sample.sourceRecordingID {
                    Text(src)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 110, alignment: .trailing)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var durationString: String {
        let s = Int(sample.duration)
        if s >= 60 { return "\(s / 60):\(String(format: "%02d", s % 60))" }
        return "\(s)s"
    }

    private func qualityColor(_ q: Float) -> Color {
        if q >= 0.7 { return .green }
        if q >= 0.4 { return .orange }
        return .red
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let url: URL
    @State private var peaks: [Float] = []

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                let mid = size.height / 2
                let slot = size.width / CGFloat(peaks.count)
                let barWidth = max(1.0, slot * 0.7)
                for (i, p) in peaks.enumerated() {
                    let h = max(1.0, CGFloat(p) * size.height)
                    let x = CGFloat(i) * slot + (slot - barWidth) / 2
                    let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                    ctx.fill(Path(rect), with: .color(.accentColor.opacity(0.55)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: url.path) {
                let target = max(20, Int(geo.size.width / 3))
                peaks = await Self.loadPeaks(url: url, target: target)
            }
        }
    }

    /// Read `target` peak magnitudes across the audio file. Uses AVAudioFile
    /// sample-by-sample max abs per bucket. Cheap enough for a 10s clip.
    static func loadPeaks(url: URL, target: Int) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0 else { return [] }
            let fmt = file.processingFormat
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return [] }
            do { try file.read(into: buf) } catch { return [] }
            guard let channel = buf.floatChannelData?[0] else { return [] }
            let n = Int(buf.frameLength)
            let bucketSize = max(1, n / target)
            var peaks: [Float] = []
            peaks.reserveCapacity(target)
            var i = 0
            while i < n {
                let end = min(i + bucketSize, n)
                var peak: Float = 0
                for k in i..<end {
                    let v = abs(channel[k])
                    if v > peak { peak = v }
                }
                peaks.append(peak)
                i = end
            }
            // Normalize to 0..1 against max
            let maxP = peaks.max() ?? 1
            if maxP > 0 {
                peaks = peaks.map { $0 / maxP }
            }
            return peaks
        }.value
    }
}

// MARK: - Avatar

struct AvatarCircle: View {
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(color)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        if let first = parts.first, let last = parts.dropFirst().first {
            return String(first.prefix(1) + last.prefix(1)).uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    private var color: Color {
        // Deterministic hue from name
        var h: UInt32 = 2166136261
        for byte in name.utf8 {
            h ^= UInt32(byte)
            h &*= 16777619
        }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

// MARK: - Merge Picker

struct MergePickerView: View {
    let person: Person
    @ObservedObject var store: PeopleStore
    let onMerge: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    private var candidates: [Person] {
        store.people.filter { $0.id != person.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge into \(person.name)")
                .font(.headline)
            Text("Pick the person whose samples should be moved into \(person.name). The other person will be deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(candidates, selection: $selection) { p in
                HStack {
                    AvatarCircle(name: p.name, size: 24)
                    VStack(alignment: .leading) {
                        Text(p.name).font(.system(size: 13))
                        Text("\(p.sampleCount) samples").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tag(p.id)
            }
            .frame(minHeight: 200)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Merge") {
                    if let id = selection, let src = candidates.first(where: { $0.id == id }) {
                        onMerge(src)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 380, height: 360)
    }
}

// MARK: - Split Picker

struct SplitPickerView: View {
    let person: Person
    @ObservedObject var store: PeopleStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split \(person.name)")
                .font(.headline)
            Text("Pick the samples that belong to a different person. They'll be moved into a new person profile.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("New person name", text: $newName)
                .textFieldStyle(.roundedBorder)

            List(person.samples, selection: $selected) { sample in
                HStack {
                    Image(systemName: selected.contains(sample.id) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected.contains(sample.id) ? Color.accentColor : .secondary)
                        .onTapGesture {
                            if selected.contains(sample.id) { selected.remove(sample.id) }
                            else { selected.insert(sample.id) }
                        }
                    VStack(alignment: .leading) {
                        Text("\(Int(sample.duration))s")
                            .font(.system(size: 12))
                        Text(sample.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selected.contains(sample.id) { selected.remove(sample.id) }
                    else { selected.insert(sample.id) }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Split") {
                    store.split(person: person, sampleIDs: selected, newName: newName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || newName.trimmingCharacters(in: .whitespaces).isEmpty
                          || selected.count == person.sampleCount)
            }
        }
        .padding(20)
        .frame(width: 420, height: 420)
    }
}

// MARK: - Live Sample Recorder

struct LiveSampleRecorderView: View {
    let personName: String
    let onSaved: (URL, Double, [Float], Float?) -> Void
    let transcriptionService: TranscriptionService

    @Environment(\.dismiss) private var dismiss

    @State private var recorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var elapsed: TimeInterval = 0
    @State private var tempURL: URL?
    @State private var timer: Timer?
    @State private var status: String = "Press record and speak for ~10 seconds."
    @State private var isExtracting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Record sample for \(personName)")
                .font(.headline)

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ZStack {
                Circle()
                    .fill(isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 90, height: 90)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
            }
            .contentShape(Circle())
            .onTapGesture {
                if isRecording { stopRecording() } else { startRecording() }
            }

            Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .foregroundStyle(isRecording ? .red : .primary)

            if isExtracting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Extracting embedding…").font(.caption)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    cancelAndClose()
                }
            }
        }
        .padding(24)
        .frame(width: 360, height: 420)
    }

    private func startRecording() {
        error = nil
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-sample-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let rec = try AVAudioRecorder(url: tmp, settings: settings)
            guard rec.record() else {
                self.error = "Failed to start recording"
                return
            }
            recorder = rec
            tempURL = tmp
            isRecording = true
            elapsed = 0
            status = "Recording — speak naturally, stop around 10 seconds."
            let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                elapsed = rec.currentTime
            }
            timer = t
        } catch {
            self.error = "Mic error: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        let duration = recorder?.currentTime ?? elapsed
        isRecording = false
        recorder = nil
        guard let url = tempURL else { return }
        guard duration >= 2 else {
            error = "Too short — record at least 2 seconds."
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
            status = "Press record and speak for ~10 seconds."
            return
        }
        isExtracting = true
        status = "Extracting embedding…"
        Task {
            do {
                let dia = try await transcriptionService.prepareDiarizer()
                let result = try await dia.process(url)
                // Best segment by quality (fall back to longest)
                let best = result.segments
                    .filter { !$0.embedding.isEmpty }
                    .max(by: { $0.qualityScore < $1.qualityScore })
                let embedding: [Float]
                let quality: Float?
                if let best {
                    embedding = best.embedding
                    quality = best.qualityScore
                } else if let db = result.speakerDatabase?.values.first(where: { !$0.isEmpty }) {
                    embedding = db
                    quality = nil
                } else {
                    await MainActor.run {
                        self.error = "Could not extract a voice embedding from that clip. Try again in a quieter environment."
                        self.isExtracting = false
                        try? FileManager.default.removeItem(at: url)
                        self.tempURL = nil
                    }
                    return
                }
                await MainActor.run {
                    onSaved(url, duration, embedding, quality)
                    isExtracting = false
                    tempURL = nil
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = "Embedding failed: \(error.localizedDescription)"
                    self.isExtracting = false
                    try? FileManager.default.removeItem(at: url)
                    self.tempURL = nil
                }
            }
        }
    }

    private func cancelAndClose() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        recorder = nil
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        tempURL = nil
        dismiss()
    }
}
