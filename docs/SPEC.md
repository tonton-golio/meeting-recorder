# Meeting Recorder — Product Specification

## What It Is

A macOS menu bar app that records audio, transcribes it locally on-device, identifies speakers by matching voices against a library of known people, and saves structured transcripts.

All processing is local. No cloud APIs. No internet required after initial model download.

## Core Concepts

### Recordings
An audio recording with its transcript. Recordings live in a sidebar list. Each recording has:
- Title (auto-generated from timestamp, editable)
- Date and time
- Duration
- Audio file size (if audio still present)
- Status: recording / recorded / transcribing / transcribed / saved
- Transcript (text with speaker labels and timestamps)
- Notes (free-form text the user can add)

Audio files can be deleted independently of the transcript to save disk space.

### People
A known person whose voice the system can recognize. Each person has:
- Name
- One or more voice samples (short audio clips, ~5-30 seconds each)
- A voice embedding per sample (256-dim vector, computed automatically)
- An aggregate embedding (average of all sample embeddings)

Multiple samples per person improve recognition accuracy, especially when recordings are made in different environments or with different microphones.

### Voice Matching
When a recording is transcribed, speakers are diarized (clustered by voice). Each speaker cluster's embedding is compared against every stored sample of every known person, and the **maximum** cosine similarity across that person's samples is used as their match score. This is what makes a single person recognisable in multiple environments (in-person vs Zoom vs headphones): whichever stored sample sounds closest to the new clip wins, rather than all samples being averaged into one muddy vector.

If the top person's best-sample score exceeds the auto-match threshold (default 0.62), the speaker is labeled with that person's name. Otherwise they get a generic label ("Speaker 1", "Speaker 2") and the user is prompted to identify them.

Thresholds are tunable in Settings → Speaker Matching, and the same panel can analyze the current People library (intra-person vs inter-person cosine distributions) to suggest an equal-error-rate threshold.

### Source-aware matching

For recordings that capture both microphone and system audio, the app keeps the raw side-channel stems next to the final mixed WAV while the audio is retained. During diarization, each speaker cluster is compared against the mic and system stems to infer whether that speaker came mostly from the local microphone, system audio, a mix of both, or an unknown source.

Voice samples store this capture source. Matching remains max-over-samples cosine matching, but uses source as a light tie-breaker: same-source samples get a small boost, mic-vs-system mismatches get a small penalty, and unknown-source samples are left unchanged.

### System-audio reliability

System audio capture prefers the display containing the mouse, then the main display, to avoid accidentally binding ScreenCaptureKit to the wrong display in multi-monitor setups. Each capture logs a diagnostic report with audio-buffer counts, conversion failures, peak/RMS levels, and output file size. When a system stem is audible but quieter than the microphone, the offline mix applies bounded automatic gain to make remote speakers easier for transcription to hear.

### Sample selection
When a voice sample is created from a recording, the app picks the longest segment where only that speaker was active (no cross-talk), clamped to 3–15 seconds, trimming the first 0.5s to skip utterance onsets. The embedding stored with the sample is the diarizer's session centroid for that speaker when available — more stable than any single window.

### Recommendations
After transcription, for each unidentified speaker the system shows:
- The top matching people (with similarity scores), so the user can confirm
- An option to create a new person
- An option to add the voice clip to an existing person (improving future recognition)

### Contamination guard
When the user assigns a clip to an existing person whose samples are very dissimilar (max cosine < 0.30), a confirmation alert appears before the clip is persisted — a guard against mis-attribution poisoning a known voice profile.

### Re-embedding on model upgrade
Every sample records the embedding model version used to compute it. If a future FluidAudio/WeSpeaker upgrade bumps that version, the People sheet surfaces a "stale" badge per sample and exposes a **Re-compute** action that re-extracts embeddings from the stored `.caf` audio using the current model.

### Disk-space pre-flight
Before recording, the app checks if less than 500 MB is free on the recordings disk. Before model download (transcription), it checks if less than 4 GB is free. If low, an alert warns the user with "Continue Anyway" / "Cancel" options. The operation is not blocked — only a warning.

## Pages / Views

### 1. Sidebar (always visible)

The left panel. Contains:

**Record Button**
- Prominent button at top: "Record" / "Stop (MM:SS)"
- Starts/stops audio recording
- While recording, shows elapsed time
- Keyboard shortcut: Cmd+R toggles recording (start if idle, stop if running). Window-level only, not a global hotkey.
- On first press, checks microphone permission. If not determined, requests access. If denied/restricted, shows an alert with "Open System Settings" button linking to Privacy > Microphone.

**Recordings List**
- All recordings, newest first, grouped by date (Today, Yesterday, This Week, Older)
- Each row shows:
  - Status indicator (dot: recording=red, recorded=gray, transcribing=spinner, transcribed=blue, saved=green)
  - Title (editable)
  - Timestamp (e.g. "Apr 10, 22:27")
  - Duration (e.g. "1m 57s")
  - Audio file size if file exists (e.g. "3 MB"), or nothing if deleted
- Right-click context menu on each row:
  - Rename
  - Reveal in Finder (opens audio file location, or markdown if no audio)
  - Delete audio file (keeps transcript and notes)
  - Delete recording entirely
- Clicking a row selects it and shows it in the main view
- Search bar at top to filter by title, date, and transcript content (full-text search)
  - When a search match is in the transcript only, a small magnifying glass icon appears on the row

**Footer**
- Settings button (opens settings sheet)
- People button (opens people management sheet)

### 2. Main View — Recording Detail (right panel)

Shown when a recording is selected from the sidebar. Contains:

**Header**
- Recording title (double-click to edit)
- Date, duration, file size
- Status pills (Transcribed, Saved). The "Saved" pill reverts to pending when the transcript is edited, notes change, speakers are confirmed post-save, or the recording is renamed.
- "Re-prompt skipped" button (visible only when speakers were skipped during confirmation). Moves skipped speakers back into the confirmation queue.
- "Notes" toggle button — shows/hides the notes panel
- "..." menu with:
  - Reveal audio in Finder (disabled if no audio file)
  - Reveal markdown in Finder (disabled if not yet saved)
  - Delete audio file
  - Remove entirely

**Transcript Area**
- Scrollable transcript with speaker labels
- Each segment shows:
  - Speaker avatar (colored circle with initial)
  - Speaker name
  - Timestamp
  - Transcribed text
- "Edit" button in the transcript header toggles an editing mode: the formatted transcript is replaced by a single TextEditor where the user can fix transcription errors. Clicking "Done" commits changes back to the recording.
- If not yet transcribed: "No transcript yet" with a Transcribe button

**Audio Player**
- Play/pause button, seek bar, current time / total time
- Only visible when audio file exists

**Notes**
- Toggleable panel between header and transcript, activated by the "Notes" button in the header
- Free-form TextEditor, auto-saves after 800ms typing pause via debounced persistence
- Notes are persisted to `recordings.json` via `RecordingEntry.notes`
- Emitted as a "## Notes" section in saved markdown (before "## Transcript"), when non-empty

**Action Bar (floating at bottom)**
- Transcribe / Re-transcribe button (disabled when audio file has been deleted)
- Save to markdown button

**New Speaker Prompt (shown after transcription)**
- For each unidentified speaker, shows:
  - Generic label ("Speaker 1")
  - Top person matches with similarity scores as suggestions
  - Text field to name them
  - "Add to [Person Name]" button (if recommendations exist)
  - "Create New Person" button
  - "Skip" to leave generic label (skipped speakers can be re-prompted via the header button)

### 3. Main View — Recording In Progress

Shown while recording is active (instead of recording detail):
- Large timer display
- Pulsing recording indicator
- Stop button

### 4. Main View — Empty State

Shown when no recording is selected:
- Icon and text: "Select a recording or press Record"

### 5. People Sheet

A sheet/modal for managing known people. Larger resizable window (≈860×620).

**People List (left pane)**
- All known people, sorted alphabetically
- Each row shows a coloured avatar, name, sample count, and total voice duration

**Person Detail (right pane)**
- Large avatar and name header (inline editable)
- Stat badges: Samples · Voice duration · Consistency (mean intra-sample cosine, green/orange/red) · Stale count (if any samples predate the current embedding model)
- Action bar:
  - **Record Sample** — live 10s recording with an in-app mic view; embedding is extracted immediately and the clip is added to this person (used for seeding/topping up coverage outside of meetings)
  - **Re-compute** — re-embeds every sample from its stored `.caf` using the current model (needed after a model upgrade)
  - **Merge…** — picks another person whose samples should be moved into this one; the other person is deleted
  - **Split…** — selects a subset of samples and moves them into a brand-new person
  - **Delete Person**
- Sample cards (one per sample):
  - Play/stop button
  - Waveform thumbnail drawn from the stored audio
  - Duration, quality score from the diarizer, stale badge when embedding is outdated
  - Created date and source recording ID
  - Delete button

### 6. Settings Sheet

A sheet with these sections:

**Transcription**
- Whisper model picker (tiny / base / small / medium / large) with download sizes
- Language (auto-detect if empty)
- Domain terms (comma-separated vocabulary hints, passed to WhisperKit as prompt tokens to bias transcription)

**Automation**
- Auto-transcribe after recording (toggle)
- Auto-save to markdown after transcription (toggle)

**Storage**
- Recordings directory path (with browse button)
- Markdown notes output path (with browse button)
- People pages path (with browse button) — Obsidian vault folder containing people pages. When set, speaker names in saved markdown are emitted as `[[slug|Name]]` wikilinks if a matching `.md` file exists under this path (searched recursively). If empty, feature is off.

**Auto-Delete**
- Enable/disable toggle
- Retention period (7 / 14 / 30 / 60 / 90 days)
- Mode: audio files only / everything

## Data Flow

```
Record (AudioRecorder → WAV file)
  ↓
Transcribe (WhisperKit → timestamped text segments)
  ↓
Diarize (FluidAudio → speaker segments with embeddings)
  ↓
Merge (align whisper segments with diarization labels)
  ↓
Match (compare speaker embeddings against People library)
  ↓
Prompt (ask user to identify unknown speakers)
  ↓
Save (ObsidianWriter → markdown with YAML frontmatter)
```

### Crash Recovery

On startup, the app recovers interrupted recordings:
- Entries in "recording" status with an existing audio file are recovered to "recorded" with duration parsed from the WAV header.
- Entries in "transcribing" status (crash during transcription) are reset to "recorded" so the user can retry transcription.

## Technology

- **SwiftUI** macOS 14+ app, menu bar presence
- **Swift Package Manager** for dependencies
- **WhisperKit** (argmaxinc) — on-device transcription via CoreML
- **FluidAudio** (FluidInference) — on-device speaker diarization and embeddings
- **AVFoundation** — audio recording and playback
- **No cloud APIs, no internet required** (after initial model download)

## Data Storage

All data lives under `~/.meeting-recorder/`:

```
~/.meeting-recorder/
  recordings/
    recordings.json          # index of all recordings
    20260410_154636.wav      # audio files
    20260410_154636.mic.wav  # local microphone stem, when retained
    20260410_154636.sys.wav  # system-audio stem, when retained
    20260411_130000.wav
  people/
    people.json              # index of all people, including each sample's
                             # embedding, modelVersion, qualityScore
    {uuid}/                  # per-person subdirectory
      {sample-uuid}.caf      # voice samples (kept so embeddings can be
                             # re-extracted after a model upgrade)
  meetings/                  # saved markdown transcripts
    20260410_154636-interview.md   # {recordingID}-{slug}.md
```

## Saved Markdown Format

```yaml
---
date: 2026-04-10
title: "Interview with Leonardo"
duration: "56 min"
speakers: ["[[anton-golio|Anton]]", "Leonardo"]
audio_file: "20260410_154636.wav"
tags: [meeting]
---

## Transcript

[[anton-golio|Anton]] [00:00]
Foundation that is very easy for the data scientists...

[Leonardo] [01:48]
Okay, so first of all, I'm impressed about what you have done...

## Notes

User's free-form notes here.
```

**Speaker names and wikilinks**: All entries in the `speakers:` YAML list are quoted. When a `peoplePagesPath` is configured and a matching people page file exists for a speaker, the name is emitted as an Obsidian wikilink `[[slug|Display Name]]` in both the YAML frontmatter and the transcript body. Speakers without a matching page appear as plain quoted strings.

**Speaker auto-match dedup**: When multiple diarized speakers match the same known person, only the highest-scoring match is auto-assigned; lower-scoring speakers fall back to manual recommendations.

## Menu Bar

The app lives in the macOS menu bar. The menu bar panel shows:
- Recording status (if recording: red dot + elapsed time)
- Processing status (if transcribing: spinner)
- Quick record/stop button
- Open main window button
- Quit button

## Key Design Principles

1. **Local first** — everything runs on-device, no API keys needed
2. **Record and forget** — auto-transcribe and auto-save mean the user just presses record and stop
3. **Learn over time** — the people library improves as the user identifies speakers, with multiple samples per person for robustness
4. **Non-destructive** — audio can be deleted separately from transcripts, nothing is permanently lost without explicit confirmation
5. **Fast** — transcription of a 5-minute recording takes ~11 seconds, diarization ~2 seconds
