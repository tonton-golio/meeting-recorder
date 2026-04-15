import SwiftUI

struct RecordingInProgressView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "record.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, isActive: state.isRecording)

            Text(state.elapsedString)
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)

            // Live waveforms
            VStack(spacing: 12) {
                AudioChannelView(
                    label: "Mic",
                    icon: "mic.fill",
                    color: .red,
                    levels: state.recorder.micLevelHistory
                )

                if Preferences.shared.captureSystemAudio && state.recorder.systemAudioWarning == nil {
                    AudioChannelView(
                        label: "System",
                        icon: "speaker.wave.2.fill",
                        color: .blue,
                        levels: state.recorder.systemLevelHistory
                    )
                }
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 40)

            Button {
                state.stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)

            // Amber warning when system audio capture failed
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
    }
}

// MARK: - Single Channel Waveform

struct AudioChannelView: View {
    let label: String
    let icon: String
    let color: Color
    let levels: [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            AudioWaveformView(levels: levels, color: color)
                .frame(height: 32)
        }
    }
}

// MARK: - Waveform Canvas

struct AudioWaveformView: View {
    let levels: [Float]
    var color: Color = .red

    var body: some View {
        Canvas { context, size in
            let barCount = levels.count
            guard barCount > 0 else { return }
            let spacing: CGFloat = 2
            let barWidth = max(2, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            let midY = size.height / 2

            for (i, level) in levels.enumerated() {
                let x = CGFloat(i) * (barWidth + spacing)
                let amplitude = CGFloat(level) * midY
                let barHeight = max(2, amplitude * 2)
                let rect = CGRect(
                    x: x,
                    y: midY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                )
                let opacity = 0.3 + Double(level) * 0.7
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color.opacity(opacity))
                )
            }
        }
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
