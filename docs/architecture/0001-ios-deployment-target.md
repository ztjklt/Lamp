# ADR 0001 — iOS deployment target

Date: 2026-09-04

## Decision

Lamp v1 targets **iOS 18.0** and is built with Xcode 26.6 / Swift 6.

## Why

- SwiftUI, WidgetKit, App Intents, EventKit, UserNotifications, PhotosUI, HealthKit and the legacy Speech recognizer are available.
- Interactive Live Activity buttons are supported through `LiveActivityIntent` (iOS 17+).
- `AudioRecordingIntent` is available on iOS 18+. It requires a Live Activity to remain active while recording.
- The newer `SpeechAnalyzer` API is iOS 26-only. Speech is therefore behind a provider protocol: v1 can use `SFSpeechRecognizer`; an iOS 26 implementation can be added without changing domain logic.
- iOS 18 preserves reasonable device coverage while avoiding a split partial-completion architecture.

## Permission strategy

Permissions are contextual, not requested at launch. EventKit uses the iOS 17+ full/write-only access APIs and matching usage-description keys. HealthKit remains optional and must be guarded with `isHealthDataAvailable()`.

## Sources

- https://developer.apple.com/documentation/activitykit
- https://developer.apple.com/documentation/appintents/audiorecordingintent
- https://developer.apple.com/documentation/speech
- https://developer.apple.com/documentation/eventkit/accessing-the-event-store

