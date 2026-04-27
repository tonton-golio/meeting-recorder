import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @AppStorage("whisperModel") private var whisperModel = ""
    @AppStorage("meetingLanguage") private var meetingLanguage = ""
    @AppStorage("domainTerms") private var domainTerms = ""
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("captureSystemAudio") private var captureSystemAudio = true
    @AppStorage("voiceProcessingEnabled") private var voiceProcessingEnabled = false
    @AppStorage("meetingsPath") private var meetingsPath = ""
    @AppStorage("recordingsPath") private var recordingsPath = ""
    @AppStorage("peoplePagesPath") private var peoplePagesPath = ""
    @AppStorage("retentionDays") private var retentionDays = 0
    @AppStorage("retentionMode") private var retentionMode = "audio"
    @AppStorage("autoMatchThreshold") private var autoMatchThreshold: Double = 0.55
    @AppStorage("recommendThreshold") private var recommendThreshold: Double = 0.30

    @State private var calibration: PeopleStore.CalibrationStats?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
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

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Transcription Model
                    section("Transcription Model") {
                        Picker("Whisper model", selection: $whisperModel) {
                            Text("Select a model...").tag("")
                            ForEach(TranscriptionService.availableModels, id: \.id) { model in
                                Text("\(model.name) (\(model.size))").tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: whisperModel) { _, val in
                            Preferences.shared.whisperModel = val
                        }
                        Text("Models download automatically on first use")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    divider()

                    // Language & Domain Terms
                    section("Transcription") {
                        field("Default language", help: "Per-recording override lives in the detail view") {
                            Picker("", selection: $meetingLanguage) {
                                Text("Auto-detect").tag("")
                                Text("Danish").tag("da")
                                Text("English").tag("en")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: meetingLanguage) { _, val in Preferences.shared.meetingLanguage = val }
                        }
                        field("Domain terms", help: "Comma-separated vocabulary hints") {
                            TextField("e.g. Kubernetes, RLHF", text: $domainTerms)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onChange(of: domainTerms) { _, val in Preferences.shared.domainTerms = val }
                        }
                    }

                    divider()

                    // Automation
                    section("Automation") {
                        Toggle("Auto-transcribe after recording", isOn: $autoTranscribe)
                            .onChange(of: autoTranscribe) { _, val in Preferences.shared.autoTranscribe = val }
                        Toggle("Auto-save after transcription", isOn: $autoSave)
                            .onChange(of: autoSave) { _, val in Preferences.shared.autoSave = val }
                    }

                    divider()

                    // Capture
                    section("Capture") {
                        Toggle("Capture system audio (both sides of calls)", isOn: $captureSystemAudio)
                            .onChange(of: captureSystemAudio) { _, val in Preferences.shared.captureSystemAudio = val }
                        Text("Requires Screen Recording permission (macOS will prompt on first recording). When off, only the microphone is captured.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Toggle("Cancel speaker echo (for speaker-on meetings)", isOn: $voiceProcessingEnabled)
                            .onChange(of: voiceProcessingEnabled) { _, val in Preferences.shared.voiceProcessingEnabled = val }
                        Text("Routes the mic through Apple's voice-processing engine (echo cancellation + noise suppression). Use this when you're on a call without headphones so the remote participants' voices don't bleed back into your mic recording. Off by default — has no effect when you're using headphones.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    divider()

                    // Matching (speaker recognition thresholds + calibration)
                    section("Speaker Matching") {
                        field("Auto-match threshold", help: "Cosine similarity required before a diarized voice is auto-labeled with a known person.") {
                            HStack {
                                Slider(value: $autoMatchThreshold, in: 0.3...0.9, step: 0.01)
                                    .onChange(of: autoMatchThreshold) { _, val in
                                        Preferences.shared.autoMatchThreshold = Float(val)
                                    }
                                Text(String(format: "%.2f", autoMatchThreshold))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }

                        field("Recommend threshold", help: "Below auto-match: cutoff for suggesting a person as a manual match.") {
                            HStack {
                                Slider(value: $recommendThreshold, in: 0.1...0.6, step: 0.01)
                                    .onChange(of: recommendThreshold) { _, val in
                                        Preferences.shared.recommendThreshold = Float(val)
                                    }
                                Text(String(format: "%.2f", recommendThreshold))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }

                        if let c = calibration {
                            calibrationReport(c)
                        } else {
                            Button("Analyze library") {
                                calibration = appState.peopleStore.calibrationStats()
                            }
                            .controlSize(.small)
                            Text("Runs cosine similarities over your current People library to suggest a threshold.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    divider()

                    // Storage
                    section("Storage") {
                        pathField("Recordings", path: $recordingsPath) {
                            Preferences.shared.recordingsPath = recordingsPath
                        }
                        pathField("Notes output", path: $meetingsPath) {
                            Preferences.shared.meetingsPath = meetingsPath
                        }
                        pathField("People pages", path: $peoplePagesPath) {
                            Preferences.shared.peoplePagesPath = peoplePagesPath
                        }
                        Text("Obsidian vault folder with people pages. If set, speaker names link to matching pages via [[wikilinks]].")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    divider()

                    // Retention
                    section("Auto-Delete") {
                        Toggle("Auto-delete old recordings", isOn: Binding(
                            get: { retentionDays > 0 },
                            set: { enabled in
                                retentionDays = enabled ? 30 : 0
                                Preferences.shared.retentionDays = retentionDays
                            }
                        ))

                        if retentionDays > 0 {
                            HStack(spacing: 8) {
                                Text("Delete after")
                                    .font(.system(size: 12))
                                Picker("", selection: $retentionDays) {
                                    Text("7 days").tag(7)
                                    Text("14 days").tag(14)
                                    Text("30 days").tag(30)
                                    Text("60 days").tag(60)
                                    Text("90 days").tag(90)
                                }
                                .pickerStyle(.menu)
                                .frame(width: 120)
                                .onChange(of: retentionDays) { _, val in
                                    Preferences.shared.retentionDays = val
                                }
                            }

                            Picker("Mode", selection: $retentionMode) {
                                Text("Audio files only").tag("audio")
                                Text("Everything").tag("all")
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 12))
                            .onChange(of: retentionMode) { _, val in
                                Preferences.shared.retentionMode = val
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 440, height: 520)
        .font(.system(size: 13))
        .onAppear {
            if meetingsPath.isEmpty { meetingsPath = Preferences.shared.meetingsPath }
            if recordingsPath.isEmpty { recordingsPath = Preferences.shared.recordingsPath }
            // peoplePagesPath is intentionally left empty by default (feature off)
            // Migrate stale free-text values ("Danish or English", etc.) to valid picker tags
            if !["", "da", "en"].contains(meetingLanguage) {
                meetingLanguage = ""
                Preferences.shared.meetingLanguage = ""
            }
        }
    }

    // MARK: - Helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func divider() -> some View {
        Divider().padding(.vertical, 16)
    }

    private func field(_ label: String, help: String = "", @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
            if !help.isEmpty {
                Text(help)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func calibrationReport(_ c: PeopleStore.CalibrationStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                distributionStat(label: "Same person", values: c.intra, tint: .green)
                distributionStat(label: "Different people", values: c.inter, tint: .red)
            }
            if let suggestion = c.suggestedThreshold {
                HStack(spacing: 8) {
                    Text("Suggested threshold:")
                        .font(.system(size: 11))
                    Text(String(format: "%.2f", suggestion))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Button("Apply") {
                        autoMatchThreshold = Double(suggestion)
                        Preferences.shared.autoMatchThreshold = suggestion
                    }
                    .controlSize(.mini)
                }
                .padding(.top, 4)
            } else {
                Text("Need at least one person with ≥2 samples and another person to calibrate.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button("Re-analyze") {
                calibration = appState.peopleStore.calibrationStats()
            }
            .controlSize(.mini)
        }
        .padding(.top, 4)
    }

    private func distributionStat(label: String, values: [Float], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            if values.isEmpty {
                Text("n/a").font(.caption2).foregroundStyle(.tertiary)
            } else {
                let mean = values.reduce(0, +) / Float(values.count)
                let sorted = values.sorted()
                let minV = sorted.first ?? 0
                let maxV = sorted.last ?? 0
                Text("n=\(values.count)  μ=\(String(format: "%.2f", mean))  [\(String(format: "%.2f", minV))..\(String(format: "%.2f", maxV))]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathField(_ label: String, path: Binding<String>, onUpdate: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12, weight: .medium))
            HStack {
                TextField(label, text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onChange(of: path.wrappedValue) { _, _ in onUpdate() }
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                        onUpdate()
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
            }
        }
        .padding(.bottom, 4)
    }
}
