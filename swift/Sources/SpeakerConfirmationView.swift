import AVFoundation
import SwiftUI

struct SpeakerConfirmationView: View {
    @ObservedObject var state: AppState

    private var hasMatchedSpeakers: Bool {
        state.pendingSpeakers.contains { $0.isHighConfidence }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Label("Confirm speakers", systemImage: "person.badge.clock")
                    .font(.subheadline.weight(.medium))

                Spacer()

                if hasMatchedSpeakers {
                    Button("Confirm All Matched") {
                        state.confirmAllMatched()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            ForEach(state.pendingSpeakers) { speaker in
                SpeakerConfirmationRow(
                    state: state,
                    speaker: speaker,
                    onConfirm: {
                        state.confirmSpeaker(speaker)
                    },
                    onAddToExisting: { person in
                        state.addSpeakerToExistingPerson(speaker, person: person)
                    },
                    onCreateNew: { name in
                        state.saveSpeakerAsNewPerson(speaker, name: name)
                    },
                    onAddSnippetToExisting: { person in
                        state.addSpeakerToExistingPerson(speaker, person: person)
                    },
                    onSkip: {
                        state.skipSpeaker(speaker)
                    }
                )
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

// MARK: - Speaker Row

struct SpeakerConfirmationRow: View {
    @ObservedObject var state: AppState
    let speaker: DetectedSpeaker
    let onConfirm: () -> Void
    let onAddToExisting: (Person) -> Void
    let onCreateNew: (String) -> Void
    let onAddSnippetToExisting: (Person) -> Void
    let onSkip: () -> Void

    @State private var showingAlternatives = false
    @State private var newName = ""
    @State private var snippetPlayer: SpeakerSnippetPlayer?

    /// True when the typed name matches an existing person. Used to surface an
    /// inline duplicate-name warning — direct prevention of the "Andreas Golles"
    /// bug, where a duplicate Person was silently created.
    private var duplicateMatch: Person? {
        state.peopleStore.personWithName(newName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Speaker label
                Text(speaker.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.blue.opacity(0.6)))

                // 5-second audio snippet player (disambiguation by ear)
                snippetButton

                // Confidence badge — muted tint, not traffic-light saturation
                if let pct = speaker.matchPercentage {
                    Text(pct)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            confidenceTint.opacity(0.12),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(confidenceTint.opacity(0.25), lineWidth: 0.5)
                        )
                }

                Spacer()
            }

            if speaker.isHighConfidence {
                highConfidenceRow
            } else if speaker.hasRecommendations {
                recommendationsRow
            } else {
                noMatchRow
            }
        }
        .padding(.vertical, 6)
    }

    private var confidenceTint: Color {
        guard let score = speaker.matchScore else { return .secondary }
        if score >= PeopleStore.defaultAutoMatchThreshold { return .green }
        if score >= 0.40 { return .orange }
        return .secondary
    }

    // MARK: - Snippet Playback

    @ViewBuilder
    private var snippetButton: some View {
        if let url = snippetAudioURL {
            Button {
                if snippetPlayer?.isPlaying == true {
                    snippetPlayer?.stop()
                } else {
                    let player = SpeakerSnippetPlayer()
                    player.play(
                        url: url,
                        startSeconds: speaker.sampleStartTime,
                        endSeconds: min(speaker.sampleStartTime + 5, speaker.sampleEndTime)
                    )
                    snippetPlayer = player
                }
            } label: {
                Image(systemName: snippetPlayer?.isPlaying == true ? "stop.circle" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Play 5-second voice sample")
        }
    }

    private var snippetAudioURL: URL? {
        guard let rec = state.selectedRecording else { return nil }
        return state.recordingStore.audioURL(for: rec)
    }

    // MARK: - High Confidence (matched person)

    private var highConfidenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(speaker.assignedName)
                    .font(.callout.weight(.medium))

                Button("Confirm") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(showingAlternatives ? "Cancel" : "Change") {
                    showingAlternatives.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if showingAlternatives {
                alternativesPanel
            }
        }
    }

    // MARK: - Recommendations (low confidence)

    private var recommendationsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !speaker.recommendations.isEmpty {
                HStack(spacing: 6) {
                    Text("Matches:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(speaker.recommendations.prefix(3)) { rec in
                        Button {
                            onAddToExisting(rec.person)
                        } label: {
                            HStack(spacing: 3) {
                                Text(rec.person.name)
                                    .font(.caption)
                                Text(rec.percentageString)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            newPersonRow
        }
    }

    // MARK: - No Match

    private var noMatchRow: some View {
        newPersonRow
    }

    // MARK: - Shared: new person + skip

    private var newPersonRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Name this speaker", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .frame(maxWidth: 180)
                    .onSubmit { submitName() }

                if let dup = duplicateMatch {
                    Button {
                        onAddSnippetToExisting(dup)
                    } label: {
                        Label("Add to \(dup.name)", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Create New Person") {
                        submitName()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if let dup = duplicateMatch {
                Label("A person named \"\(dup.name)\" already exists — add this voice to them instead.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func submitName() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The duplicate-guard button handles "add to existing"; this path is
        // reached only when no existing match was found or the user submitted
        // via return before the duplicate UI appeared.
        if let dup = duplicateMatch {
            onAddSnippetToExisting(dup)
        } else {
            onCreateNew(trimmed)
        }
    }

    // MARK: - Alternatives panel (for changing a high-confidence match)

    private var alternativesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !speaker.recommendations.isEmpty {
                HStack(spacing: 6) {
                    Text("Other matches:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(speaker.recommendations.prefix(3)) { rec in
                        Button {
                            onAddToExisting(rec.person)
                        } label: {
                            HStack(spacing: 3) {
                                Text(rec.person.name)
                                    .font(.caption)
                                Text(rec.percentageString)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            newPersonRow
        }
        .padding(.leading, 4)
    }
}

// MARK: - Snippet Player

/// Lightweight AVAudioPlayer wrapper that plays a fixed window
/// [startSeconds, endSeconds] from a file, then stops. Used for the 5-second
/// voice preview next to each unidentified speaker in the confirmation UI.
@MainActor
final class SpeakerSnippetPlayer: ObservableObject {
    @Published var isPlaying = false
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(url: URL, startSeconds: Double, endSeconds: Double) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.currentTime = max(0, startSeconds)
            p.play()
            player = p
            isPlaying = true
            let duration = max(0.5, endSeconds - startSeconds)
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                await MainActor.run { self?.stop() }
            }
        } catch {
            NSLog("[SpeakerSnippetPlayer] failed: \(error)")
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}
