import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Record / Status section
            statusSection
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // Recent recordings
            recentRecordingsSection
                .padding(.vertical, 6)

            Divider()

            // Quick info row
            infoBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Actions
            VStack(spacing: 2) {
                Button {
                    Self.showMainWindow()
                } label: {
                    Label("Open Meeting Recorder", systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Button {
                    Self.showMainWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        state.showPeople = true
                    }
                } label: {
                    Label("People & Voices", systemImage: "person.wave.2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Button {
                    Self.showMainWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        state.showSettings = true
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .padding(.vertical, 4)

            Divider()

            // Hotkey hint + Quit
            HStack {
                Text("Ctrl+Opt+R to record from anywhere")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Button("Quit Meeting Recorder") {
                if state.isRecording {
                    Task {
                        await state.stopRecordingAndWait()
                        state.recordingStore.flush()
                        await MainActor.run { NSApplication.shared.terminate(nil) }
                    }
                } else {
                    state.recordingStore.flush()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .padding(.bottom, 4)
        }
        .frame(width: 320)
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        if state.isRecording {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                    Text("Recording").font(.headline)
                    Spacer()
                    Text(state.elapsedString)
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }

                Button {
                    state.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            }
        } else if state.transcribeStep == .running || state.saveStep == .running {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Processing...").font(.headline)
                }
                Text(state.statusMessage.isEmpty ? "Working..." : state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    stepIndicator("Transcribe", step: state.transcribeStep)
                    stepIndicator("Save", step: state.saveStep)
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting Recorder").font(.headline)
                    Text("Ready to record").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Recent Recordings

    private var recentRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            if state.recordingStore.recordings.isEmpty {
                Text("No recordings yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(state.recordingStore.recordings.prefix(4)) { entry in
                    Button {
                        state.selectRecording(entry)
                        Self.showMainWindow()
                    } label: {
                        HStack(spacing: 8) {
                            statusDot(entry)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(entry.dateFormatted)
                                    if entry.duration > 0 {
                                        Text("·")
                                        Text(entry.durationFormatted)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.status == "saved" {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ entry: RecordingEntry) -> some View {
        switch entry.status {
        case "saved":
            Circle().fill(.green).frame(width: 7, height: 7)
        case "transcribed":
            Circle().fill(.blue).frame(width: 7, height: 7)
        case "transcribed_raw":
            Circle().fill(.yellow).frame(width: 7, height: 7)
        case "transcribing":
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        case "recording":
            Circle().fill(.red).frame(width: 7, height: 7)
        default:
            Circle().fill(.quaternary).frame(width: 7, height: 7)
        }
    }

    // MARK: - Info Bar

    private var infoBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "person.wave.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(state.peopleStore.people.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(state.peopleStore.people.count == 1 ? "voice" : "voices")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if Preferences.shared.captureSystemAudio {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("System audio on")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Mic only")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text("\(state.recordingStore.recordings.count) recordings")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Window Management

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        for window in NSApp.windows where window.frame.width > 400 {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    private func stepIndicator(_ label: String, step: PipelineStep) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().fill(step.color.opacity(0.2)).frame(width: 20, height: 20)
                switch step {
                case .pending: Circle().fill(.quaternary).frame(width: 6, height: 6)
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
                case .failed: Image(systemName: "xmark").font(.caption2).foregroundStyle(.red)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
