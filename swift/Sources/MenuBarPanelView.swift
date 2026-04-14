import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusSection
                .padding(.horizontal, 4)

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Meeting Recorder", systemImage: "macwindow")
            }

            Divider()

            Button("Quit Meeting Recorder") {
                if state.isRecording {
                    // Await full stop (WAV finalization) before terminating to avoid losing the recording.
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
        }
        .padding(8)
        .frame(width: 260)
    }

    @ViewBuilder
    private var statusSection: some View {
        if state.isRecording {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                    Text("Recording").font(.headline)
                }
                Text(state.elapsedString)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()

                Button {
                    state.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        } else if state.transcribeStep == .running || state.saveStep == .running {
            VStack(alignment: .leading, spacing: 4) {
                Text("Processing...")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 12) {
                    stepIndicator("T", step: state.transcribeStep)
                    stepIndicator("S", step: state.saveStep)
                }
            }
        } else {
            HStack {
                Label("Ready", systemImage: "mic.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }

    private func stepIndicator(_ letter: String, step: PipelineStep) -> some View {
        ZStack {
            Circle().fill(step.color.opacity(0.2)).frame(width: 24, height: 24)
            switch step {
            case .pending: Text(letter).font(.caption2).foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.mini)
            case .done: Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
            case .failed: Image(systemName: "xmark").font(.caption2).foregroundStyle(.red)
            }
        }
    }
}
