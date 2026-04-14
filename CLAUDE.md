# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Meeting Recorder is a native macOS menu bar app (SwiftUI, macOS 14+, arm64) that records audio, transcribes it locally using WhisperKit, performs speaker diarization with FluidAudio, and saves structured transcripts to Obsidian-compatible markdown. All processing runs on-device — no cloud APIs required.

## Build & Run

```bash
cd swift
./build.sh          # SPM build, bundles .app, signs, installs to /Applications
open -a "Meeting Recorder"
```

Uses **Swift Package Manager** (`Package.swift`). First build downloads dependencies + Whisper models.

## Architecture

### Dependencies (SPM)
- **WhisperKit** (argmaxinc) — on-device speech-to-text via CoreML
- **FluidAudio** (FluidInference) — on-device speaker diarization (Pyannote + WeSpeaker)

### Data Flow

```
AudioRecorder (WAV, 16kHz mono)
  → TranscriptionService
      → WhisperKit (local transcription)
      → FluidAudio (speaker diarization)
      → PeopleStore (match speakers to known people)
  → MarkdownWriter (markdown + YAML frontmatter)
```

### Key Components

- **AppState** (`AppState.swift`): Central `@MainActor ObservableObject`. Slim coordinator owning RecordingStore, PeopleStore, TranscriptionService, AudioRecorder, AudioPlayer. Recording lifecycle, pipeline orchestration.
- **RecordingStore** (`RecordingStore.swift`): `@MainActor ObservableObject`. Manages `recordings.json` index, CRUD, orphan scanning, retention cleanup, WAV duration parsing.
- **PeopleStore** (`PeopleStore.swift`): `@MainActor ObservableObject`. Manages known people with multiple voice samples per person. Two-tier matching (auto-match at 0.55 + recommendations at 0.25). Handles legacy VoicePrint migration. Stores data in `~/.meeting-recorder/people/` with subdirectories per person.
- **TranscriptionService** (`TranscriptionService.swift`): Orchestrates WhisperKit transcription + FluidAudio diarization + PeopleStore matching. Produces transcript with speaker labels and recommendations for unidentified speakers.
- **AudioRecorder** (`AudioRecorder.swift`): Simple AVAudioRecorder. Records 16kHz/16-bit mono WAV.
- **AudioPlayer** (`AudioPlayer.swift`): AVAudioPlayer wrapper with playback state tracking.
- **MarkdownWriter** (`MarkdownWriter.swift`): Saves markdown with YAML frontmatter including `speakers` field. Extracts speaker names from transcript.
- **Preferences** (`Preferences.swift`): UserDefaults singleton. Whisper model selection, automation toggles, paths, retention.

### UI Structure

Single-surface layout:
- **MainView** (`MainView.swift`): NavigationSplitView with sidebar + detail
  - **Sidebar**: Record button, recordings list (grouped by Today/Yesterday/This Week/Older) with search, right-click context menus, footer with Settings + People buttons
  - **Detail**: Delegates to RecordingDetailView, RecordingInProgressView, or empty state
- **RecordingDetailView** (`RecordingDetailView.swift`): Header with title/date/status pills, transcript with speaker avatars, audio player, togglable notes panel, floating action bar
- **RecordingInProgressView** (`RecordingInProgressView.swift`): Pulsing recording indicator, timer, stop button
- **NewSpeakerPromptView** (`NewSpeakerPromptView.swift`): Post-transcription speaker identification with similarity-scored recommendations, "Add to [Person]", "Create New Person", and "Skip" options
- **PeopleSheet** (`PeopleSheet.swift`): List-detail management for known people. Person detail shows voice samples with play/delete, rename, delete person
- **SettingsSheet** (`SettingsSheet.swift`): Model picker, language, domain terms, automation toggles, storage paths, retention
- **MenuBarPanelView** (`MenuBarPanelView.swift`): Quick record/stop, processing status, open window, quit

### Data Storage

```
~/.meeting-recorder/
  recordings/
    recordings.json          # index of all recordings
    *.wav                    # audio files
  people/
    people.json              # index of all people
    {uuid}/                  # per-person subdirectory
      {sample-uuid}.caf     # voice samples
  meetings/                  # saved markdown transcripts
    *.md
```

### Models (Models.swift)

- **RecordingEntry**: id, filename, date, duration, title, status, transcript, notes
- **Person**: id, name, samples (VoiceSample[]), aggregateEmbedding, timestamps
- **VoiceSample**: id, embedding (256-dim), duration, sourceRecordingID, timestamp
- **DetectedSpeaker**: label, embedding, matchedPerson, assignedName, sampleTimes, recommendations
- **SpeakerRecommendation**: person, similarity score
- **PipelineStep**: pending/running/done/failed

### Speaker Recognition Flow

1. After transcription, FluidAudio diarizes audio into speaker segments
2. For each speaker, extract WeSpeaker embedding (256-dim vector)
3. Compare against People library aggregate embeddings (cosine similarity)
4. Auto-match if similarity > 0.55 → use person's name
5. Show recommendations if similarity > 0.25 → user can confirm match
6. Unknown speakers → prompt to name and create new person or add to existing
7. Multiple samples per person improve accuracy (embeddings averaged, L2-normalized)

### Transcript Format

```
[Speaker Name] [MM:SS]
Transcribed text here.

[Another Speaker] [MM:SS]
More transcribed text.
```

## Development Practices

- When choosing an LLM model for the system, always check if there is a later model that is not much more expensive.
- When adding a new package or dependency, use the latest version and read the current docs first.
- Keep the design simple during MVP. Avoid over-engineering.
- Always push back if you think a suggested approach is wrong -- the user is not an expert in this development area and values honest technical feedback.
- Maintain a `docs/` folder in the repo. Check it before starting a task, update it after completing one.
- Update the README and docs if changes should be documented.
- Keep code well formatted and linted.

## UI Guidelines

- Keep design simple for MVP.
- Always think about what clarifying questions would help understand the user's intent and vision better.
