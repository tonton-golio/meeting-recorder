import AVFoundation
import FluidAudio
import SpeakerMatchingCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var step: OnboardingStep = .welcome
    @State private var userName = ""

    enum OnboardingStep: Int, CaseIterable {
        case welcome, microphone, voice, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            Spacer()

            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .microphone:
                    microphoneStep
                case .voice:
                    VoiceRegistrationStep(
                        userName: userName,
                        state: state,
                        onComplete: { withAnimation { step = .ready } }
                    )
                case .ready:
                    readyStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Spacer()
        }
        .frame(width: 540, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tint)

            Text("Welcome to Meeting Recorder")
                .font(.title)
                .fontWeight(.semibold)

            Text("Record meetings locally, transcribe with on-device AI, and automatically identify who said what.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(spacing: 12) {
                featureRow(icon: "lock.shield", text: "Fully private — everything stays on your Mac")
                featureRow(icon: "person.wave.2", text: "Learns your voice for automatic speaker labels")
                featureRow(icon: "doc.text", text: "Saves transcripts as Obsidian-compatible markdown")
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                Text("What's your name?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { advanceFromWelcome() }
            }
            .padding(.top, 8)

            Button("Get Started") { advanceFromWelcome() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(userName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 4)
        }
        .padding(32)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: 400)
    }

    private func advanceFromWelcome() {
        let name = userName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Preferences.shared.userName = name
        withAnimation { step = .microphone }
    }

    // MARK: - Microphone Permission

    @State private var micGranted = false
    @State private var micDenied = false

    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tint)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Meeting Recorder needs your microphone to capture audio. This is the only required permission.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if micGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)

                Button("Continue") { withAnimation { step = .voice } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            } else if micDenied {
                Label("Microphone access denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)

                Text("Enable it in System Settings > Privacy & Security > Microphone, then relaunch the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                HStack(spacing: 12) {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Skip") { withAnimation { step = .voice } }
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                Button("Allow Microphone") { requestMicPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button("Skip for now") { withAnimation { step = .voice } }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .onAppear { checkMicStatus() }
    }

    private func checkMicStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
        case .denied, .restricted:
            micDenied = true
        default:
            break
        }
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                micGranted = granted
                micDenied = !granted
                if granted {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    withAnimation { step = .voice }
                }
            }
        }
    }

    // MARK: - Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Here are a few things to know:")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                tipRow(icon: "record.circle.fill", color: .red,
                       title: "Record",
                       detail: "Click the red button or press Ctrl+Opt+R from any app")
                tipRow(icon: "text.bubble", color: .blue,
                       title: "Transcribe",
                       detail: "Recordings are transcribed automatically when you stop")
                tipRow(icon: "person.wave.2", color: .purple,
                       title: "Speakers",
                       detail: "The app will recognize your voice. New speakers get prompted for a name.")
                tipRow(icon: "menubar.rectangle", color: .secondary,
                       title: "Menu bar",
                       detail: "The app lives in your menu bar — close the window and it keeps running")
            }
            .frame(maxWidth: 420)
            .padding(.top, 4)

            Button("Start Recording") {
                finishOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(32)
    }

    private func tipRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func finishOnboarding() {
        Preferences.shared.onboardingCompleted = true
        state.showOnboarding = false
        dismiss()
    }
}

// MARK: - Voice Registration Step

struct VoiceRegistrationStep: View {
    let userName: String
    let state: AppState
    let onComplete: () -> Void

    @State private var recorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var tempURL: URL?
    @State private var phase: VoicePhase = .intro
    @State private var errorMessage: String?
    @State private var audioLevel: Float = 0
    @State private var meterTimer: Timer?

    enum VoicePhase {
        case intro, recording, extracting, done, failed
    }

    static let readingPassage = """
    The sun was setting behind the hills as I walked along the quiet path. \
    Every evening I try to take a moment to reflect on what happened during the day. \
    Sometimes the best ideas come from unexpected conversations with colleagues. \
    Yesterday we discussed how to improve our workflow, and I think the \
    suggestions were quite practical. It's important to keep things simple \
    and focus on what actually matters. I've noticed that the most productive \
    meetings are the short ones where everyone gets a chance to speak.
    """

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tint)

            Text("Register Your Voice")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Read the passage below out loud so the app can learn to recognize you in meetings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            // Reading passage card
            ScrollView {
                Text(Self.readingPassage)
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxWidth: 460, maxHeight: 120)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Status area
            switch phase {
            case .intro:
                Text("Tap the microphone to start reading")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .recording:
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let normalized = CGFloat(max(0.05, min(1.0, (audioLevel + 50) / 50)))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red.opacity(0.6))
                            .frame(width: normalized * geo.size.width, height: 6)
                            .animation(.easeOut(duration: 0.1), value: audioLevel)
                    }
                    .frame(height: 6)
                    .frame(maxWidth: 200)

                    Text("Recording... read the passage above")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            case .extracting:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Creating your voice profile...").font(.caption)
                }
            case .done:
                Label("Voice registered!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .failed:
                Label(errorMessage ?? "Failed to extract voice profile", systemImage: "exclamation.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            // Record button
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 64, height: 64)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .contentShape(Circle())
            .onTapGesture {
                if phase == .done || phase == .extracting { return }
                if isRecording { stopRecording() } else { startRecording() }
            }
            .opacity(phase == .extracting || phase == .done ? 0.4 : 1)

            // Timer
            Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .foregroundStyle(isRecording ? .red : .primary)

            // Bottom buttons
            HStack(spacing: 16) {
                if phase == .done {
                    Button("Continue") { onComplete() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else if phase == .failed {
                    Button("Try Again") {
                        phase = .intro
                        errorMessage = nil
                    }
                    .controlSize(.large)
                    Button("Skip") { onComplete() }
                        .foregroundStyle(.secondary)
                } else if !isRecording && phase == .intro {
                    Button("Skip for now") { onComplete() }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }

    // MARK: - Recording

    private func startRecording() {
        errorMessage = nil
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onboarding-voice-\(UUID().uuidString).wav")
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
            rec.isMeteringEnabled = true
            guard rec.record() else {
                errorMessage = "Failed to start recording"
                phase = .failed
                return
            }
            recorder = rec
            tempURL = tmp
            isRecording = true
            elapsed = 0
            phase = .recording
            let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                elapsed = rec.currentTime
            }
            timer = t
            let mt = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                rec.updateMeters()
                audioLevel = rec.averagePower(forChannel: 0)
            }
            meterTimer = mt
        } catch {
            errorMessage = "Mic error: \(error.localizedDescription)"
            phase = .failed
        }
    }

    private func stopRecording() {
        timer?.invalidate(); timer = nil
        meterTimer?.invalidate(); meterTimer = nil
        // Capture duration BEFORE stop() — AVAudioRecorder resets currentTime to 0 after stop.
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        isRecording = false
        recorder = nil

        guard let url = tempURL else { return }

        guard duration >= 5 else {
            errorMessage = "Too short — please read more of the passage (at least 5 seconds)."
            phase = .failed
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
            return
        }

        phase = .extracting
        Task {
            do {
                let dia = try await state.transcriptionService.prepareDiarizer()
                let result = try await dia.process(url)

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
                        errorMessage = "Could not extract a voice profile. Try again in a quieter environment."
                        phase = .failed
                        try? FileManager.default.removeItem(at: url)
                        tempURL = nil
                    }
                    return
                }

                let name = userName.trimmingCharacters(in: .whitespaces)
                await MainActor.run {
                    // Check if person already exists (e.g. from a retry)
                    if let existing = state.peopleStore.people.first(where: { $0.name == name }) {
                        state.peopleStore.addSampleFromFile(
                            to: existing,
                            existingClipURL: url,
                            duration: duration,
                            embedding: embedding,
                            qualityScore: quality,
                            captureSource: .microphone
                        )
                    } else {
                        let _ = state.peopleStore.createPersonFromFile(
                            name: name,
                            existingClipURL: url,
                            duration: duration,
                            embedding: embedding,
                            qualityScore: quality,
                            captureSource: .microphone,
                            notes: "Created during onboarding"
                        )
                    }
                    withAnimation { phase = .done }
                    tempURL = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Voice profile extraction failed: \(error.localizedDescription)"
                    phase = .failed
                    try? FileManager.default.removeItem(at: url)
                    tempURL = nil
                }
            }
        }
    }
}
