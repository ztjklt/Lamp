# ADR 0005 — Locked-screen partial completion voice flow

Date: 2026-09-04

## Verified API facts

- Live Activities can expose App Intent buttons.
- `AudioRecordingIntent` is available on iOS 18+, and iOS requires a Live Activity while recording.
- Live Activities have a separate sandbox and cannot directly perform arbitrary network access.
- Lock state, authentication, microphone permission, app lifecycle and device policy can alter the result. Simulator behavior is not acceptance evidence.

## v1 decision

Ship a reliable fallback first: tapping **Partial** writes a safe partial-status intent and deep-links to a single-purpose recording sheet. If a physical-device spike proves direct recording reliable in supported lock states, add it behind a runtime capability flag.

## Physical-device acceptance checklist

- First use with microphone/speech permission undecided.
- Locked and unlocked device; Face ID success and failure.
- App terminated, suspended and foregrounded.
- Recording indicator and Live Activity lifetime.
- Mandarin transcription, cancellation and interruption.
- AirPods/Bluetooth route changes and incoming calls.
- No network: recording/transcript is retained for retry.

This gate is documented but cannot be marked hardware-validated without a signed build on a physical iPhone.

