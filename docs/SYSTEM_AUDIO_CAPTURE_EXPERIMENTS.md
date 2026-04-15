# System Audio Capture Experiments

## Working Hypotheses

When the other person is missing from a recording, the failure is usually one of:

- ScreenCaptureKit permission is denied or stale after rebuilding/signing the app.
- Audio buffers arrive, but the buffer format is not decoded correctly.
- The capture filter is tied to the wrong display in a multi-display setup.
- The system stem is present but too quiet relative to the microphone in the final mix.
- The meeting app routes call audio through a device or mode ScreenCaptureKit does not expose.

## Implemented Changes

- The capture filter now prefers the display containing the mouse, then the main display, instead of blindly using the first display returned by ScreenCaptureKit.
- System audio decoding now handles non-interleaved and interleaved float/16-bit PCM buffers explicitly.
- Each recording logs a system-audio capture report with callback count, decoded PCM buffers, conversion failures, frames written, audible buffers, peak level, and file size.
- Mixing now checks whether the system stem is actually audible and applies a bounded automatic gain to system audio before combining it with the mic.
- The app keeps the `.mic.wav` and `.sys.wav` stems while audio is retained, so failures can be audited after the fact.

## Experiment 1: Offline Capture Audit

Audit recent recordings:

```bash
cd swift
swift run Experiments capture-audit
```

Audit one recording:

```bash
cd swift
swift run Experiments capture-audit ~/.meeting-recorder/recordings/RECORDING_ID.wav
```

The report is also saved under:

```text
~/.meeting-recorder/test/results/capture-audit-*.txt
```

Interpretation:

- `missing system stem`: ScreenCaptureKit failed before writing audio.
- `system stem is silent`: permission, routing, meeting-app output, or no remote speech.
- `system stem is audible but much quieter than mic`: mixing gain is the likely fix.
- `system stem looks audible`: capture worked; issues are probably downstream transcription/diarization.

Initial local audit on April 15, 2026:

- 25 recent recordings audited.
- 15 had no system stem.
- 10 had a tiny/silent system stem.
- 0 had an audible system stem.

That baseline points to capture-layer failure rather than Whisper/diarization failure for the missing remote speaker cases.

## Experiment 2: Live Meeting Probe

Before a real meeting, play any short sound from the same app/device where the call audio will come from, then start a 10-second recording.

Expected result:

- The in-progress view should show a moving system waveform.
- The capture audit should show an audible `.sys.wav` stem.

If the waveform is flat:

- Confirm Screen Recording permission for `Meeting Recorder`.
- Toggle Screen Recording off/on after rebuilding the app.
- Move the mouse to the display where the meeting app is visible before starting recording.
- Check the meeting app's output device. If it is a special virtual or headset call device, test the system output speaker/headphones route.

## Experiment 3: Known-Sound Test

Play a locally generated tone or a short video while recording. Then run:

```bash
cd swift
swift run Experiments capture-audit ~/.meeting-recorder/recordings/RECORDING_ID.wav
```

This separates ScreenCaptureKit capture problems from meeting-app-specific routing problems. If the tone records but the call does not, the meeting app or audio route is the likely culprit.

## Bigger Options

1. Add an in-app "System audio test" button that records 5 seconds and immediately reports whether system audio is audible.
2. Offer a meeting-app/window picker and build the ScreenCaptureKit filter around the selected app/window.
3. Add a virtual audio-device fallback for users who need maximum reliability across call apps. This is more invasive and less native, but it can be more predictable than display-based ScreenCaptureKit capture.
