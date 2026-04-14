import SwiftUI

struct RecordingInProgressView: View {
    @ObservedObject var state: AppState
    @State private var pulse = true

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "record.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, isActive: pulse)

            Text(state.elapsedString)
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)

            Button {
                state.stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)

            // Amber warning when system audio capture failed (Screen Recording permission denied)
            if state.recorder.systemAudioWarning != nil && Preferences.shared.captureSystemAudio {
                VStack(spacing: 6) {
                    Label("System audio not captured", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("Only your microphone is recording. Remote speakers in calls won't be transcribed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Screen Recording Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: 360)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .task {
            // Steady timer past the first minute — less anxiety-inducing on long meetings.
            try? await Task.sleep(for: .seconds(60))
            withAnimation(.easeOut(duration: 0.4)) { pulse = false }
        }
    }
}
