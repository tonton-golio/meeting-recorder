# Speaker Identification Experiments

## Current Hypothesis

Most bad speaker-identification cases are likely caused by one or more of:

- Source mismatch: the same person sounds different through the local mic vs. captured system audio.
- Mixed-channel contamination: the final mono WAV blends local mic leakage and remote call audio before diarization.
- Library contamination: a person has samples from the wrong speaker or from a very different acoustic condition.
- Threshold drift: one global auto-match threshold is too blunt once the People library contains both mic and system samples.

## Implemented Guardrail

The recorder now keeps the raw side-channel stems next to the final mixed WAV while audio is retained:

```text
20260415_120000.wav       # mixed file used for playback/transcription
20260415_120000.mic.wav   # local microphone stem
20260415_120000.sys.wav   # system-audio stem, when available
```

During diarization, each speaker cluster is scored against those stems. If one stem has clearly stronger energy for that speaker's windows, the speaker is tagged as `Mic` or `System`; otherwise it is tagged as `Mixed` or `Unknown`.

Voice samples now store their capture source. Matching still uses max-over-samples cosine similarity, but applies a small source-aware adjustment:

- Same source: small bonus.
- Mic-vs-system mismatch: small penalty.
- Mixed source: very small penalty.
- Unknown source: no adjustment.

This should reduce close-call false matches without blocking real cross-source matches when no better same-source sample exists.

## Experiment 1: Source Audit

Run a source audit on any newly recorded meeting:

```bash
cd swift
swift run Experiments source-audit ~/.meeting-recorder/recordings/RECORDING_ID.wav
```

Output is written to:

```text
~/.meeting-recorder/test/results/source-audit-RECORDING_ID.txt
```

Review:

- Whether local participants are tagged `Mic`.
- Whether remote call participants are tagged `System`.
- Whether `Mixed` speakers correspond to crosstalk, speakerphone leakage, or overlapping speech.
- Pairwise speaker similarity, especially pairs above the auto-match threshold.

## Automated Checks

Run the lightweight source-matching checks:

```bash
cd swift
swift run SpeakerMatchingCoreChecks
```

These checks cover:

- Source-aware score adjustment and clamping.
- Mic/system/mixed/unknown source classification.
- Expected sibling stem filenames.

## Experiment 2: Threshold Sweep

For 5-10 meetings, manually note the correct speaker for every prompted speaker. Track:

- Candidate source (`Mic`, `System`, `Mixed`, `Unknown`).
- Top match name and score.
- Correct person.
- Whether the old global threshold would have auto-matched incorrectly.
- Whether the source-aware score changes the decision.

Suggested CSV columns:

```text
recording_id,speaker_label,source,top_match,top_score,correct_person,old_decision,source_aware_decision
```

Use this to tune:

- `autoMatchThreshold`
- `recommendThreshold`
- source bonus/penalty constants in `SpeakerMatchingCore`

## Experiment 3: People Library Audit

In Settings -> Speaker Matching, run "Analyze library" after adding several source-tagged samples per person.

Look for:

- Same-person mic-vs-mic scores.
- Same-person system-vs-system scores.
- Same-person mic-vs-system scores.
- Different-person scores within the same source.

If mic-vs-system scores are consistently lower, keep source-specific samples instead of averaging or over-lowering the global threshold.

## Suggested Next Improvements

1. Add a debug export that writes the threshold-sweep CSV automatically after each transcription.
2. Add a People-sheet filter/grouping by sample source so contaminated or one-off system samples are easier to inspect.
3. Consider source-specific thresholds once enough measurements exist, for example stricter auto-match on cross-source matches and more permissive matching within the same source.
4. Run diarization separately on mic and system stems, then merge the speaker timelines. This is more invasive, but it may outperform diarizing the mixed WAV when both sides speak over each other.
