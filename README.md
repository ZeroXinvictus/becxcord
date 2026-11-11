# BexxCord

Production-grade Android screen and audio recorder. Flutter renders the control surface; a native Kotlin foreground service owns the entire recording pipeline.

## Architecture

| Layer | Responsibility |
| --- | --- |
| `lib/` (Flutter) | UI, settings, library, player. No recording logic. |
| `ScreenRecordService.kt` | Foreground service (type `mediaProjection` / `microphone`), serialized command gate, telemetry loop, notification. |
| `RecordingEngine` (inside ScreenRecordService.kt) | MediaCodec encoders, MediaMuxer, VirtualDisplay, AudioRecord, segment lifecycle, finalization. |
| `RecorderChannel.kt` | Typed MethodChannel / EventChannel contract, MediaStore library store, DataStore preferences. |
| `CapabilityModel.kt` | Device capability probe and pre-start configuration validation with explicit error codes. |
| `RecorderState.kt` | Sealed state machine with metadata, telemetry and error events. |
| `BubbleService.kt` | Optional overlay control bubble (pause/resume/stop). |

## Recording pipeline

- Preferred pipeline: `MediaCodec` (surface input from `VirtualDisplay` + AAC audio encoder) into `MediaMuxer`. There is no MediaRecorder fallback; the active pipeline is reported in telemetry.
- Pause/resume uses a documented segment-based strategy: pausing closes the current muxer segment, resuming opens a fresh segment, and stopping stitches all segments into one MediaStore MP4 (sample-accurate remux with per-track timestamp offsets). A/V timestamps stay aligned because each segment restarts both encoders from zero and offsets accumulate per track during stitching.
- Commands (START / PAUSE / RESUME / STOP) are serialized through a mutex inside the service. START is rejected unless the state machine is idle, saved, interrupted or errored. STOP is idempotent.
- Every recording session requests fresh MediaProjection consent. Consent grants are single-use: starting a recording consumes the grant, and a new session needs a new consent dialog.
- MediaProjection.Callback is registered before the virtual display is created; `onStop` moves the state to `Interrupted`, attempts salvage finalization of complete segments, and releases every resource.

## Capability honesty

- Internal audio (playback capture) is only offered when `AudioPlaybackCaptureConfiguration` works on the device. If the AudioRecord fails to initialize, the engine reports `AUDIO_SYSTEM_UNAVAILABLE`, falls back to no audio or mic, and the session summary reflects the audio source that was actually captured.
- Encoders, resolutions, frame rates and bitrates are validated against `MediaCodecList` capabilities before start. Unsupported configurations are rejected with explicit codes (`CONFIG_CODEC_MISSING`, `CONFIG_RESOLUTION_UNALIGNED`, `CONFIG_FPS_UNSUPPORTED`, `CONFIG_BITRATE_OUT_OF_RANGE`, ...). Nothing is silently substituted.
- Thermal telemetry uses `PowerManager.getCurrentThermalStatus()` (API 29+) and `getThermalHeadroom()` (API 34+) only. There is no auto-quality mode; quality never changes mid-recording.
- The UI shows real states only: if the overlay permission is missing, the overlay chip offers the settings screen instead of pretending the bubble exists.

## Storage

- MediaStore (`Movies/BexxCord`) is the source of truth for recordings. Files are inserted with `IS_PENDING`, finalized with duration/size metadata, and never stored inside a database.
- Recording preferences (profile, audio toggles, countdown) are persisted with Jetpack DataStore.
- Filenames carry capability tags, e.g. `BexxCord_20260101_120000_h264_sys.mp4` (codec / audio source), so library entries and session summaries stay honest even without a sidecar database.
- Storage preflight: before every session the engine measures free bytes on the shared volume via `StatFs` and rejects the start with `STORAGE_LOW` when free space is below a five minute reserve estimated from the selected bitrates. Mid-session the telemetry loop re-checks every 500ms: below one minute of reserve it emits `STORAGE_LOW` (recoverable warning), and near exhaustion it emits `STORAGE_CRITICAL` and stops plus finalizes the session so everything recorded so far is saved instead of lost.

## Session conveniences

- Start countdown (3-2-1) is optional and lives entirely in the UI layer. It never touches the engine, never fakes a recording state, and can be cancelled at any moment before start.
- The recording notification carries Pause/Resume and Stop action buttons wired to the same serialized command gate as the in-app controls.
- Library tiles and the home recent list load real thumbnails through `ContentResolver.loadThumbnail()`; if a thumbnail cannot be decoded the tile shows an honest placeholder instead.
- Frame capture: the player can extract the frame at the current slider position from an existing recording via `MediaMetadataRetriever` and save it as a JPEG under `Pictures/BexxCord` through MediaStore. It requires no new permissions and states its source position honestly.

## Build

Requirements: Flutter stable (3.22+), JDK 17, Android SDK 35.

```bash
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
flutter build apk --release
```

GitHub Actions workflow: `.github/workflows/build.yml` (checkout, JDK 17, Flutter stable, analyze, tests, release APK, artifact upload).

## Tests

`test/recorder_state_test.dart` covers the Dart mirror of the native state machine: every `RecorderState.fromMap` branch, telemetry and capability parsing (including free storage), config serialization to the typed channel contract, and library entry parsing with honest defaults. The workflow runs `flutter test` on every push and pull request.

## App icon

Vector adaptive icon (`mipmap-anydpi-v26` + `ic_launcher_foreground.xml`): a REC ring with one segment replaced by a terminal cursor block on the dark terminal background. No text in the glyph so it stays legible down to 48dp. Source SVG and a 512px preview live in `design/`.

## Platform contract

MethodChannel `bexxcord/recorder`: initialize, requestRuntimePermissions, getCapabilities, getPreferences, saveProfile, setMicEnabled, setSystemAudioEnabled, setCountdownEnabled, requestProjection, startRecording, pauseRecording, resumeRecording, stopRecording, getRecordings, deleteRecording, renameRecording, getRecordingThumbnail, captureFrame, openOverlaySettings.

EventChannels: `bexxcord/state` (state machine), `bexxcord/telemetry` (fps, dropped frames, thermal, elapsed), `bexxcord/errors` (error events), `bexxcord/recordingProgress` (state stream for progress consumers).

## Design system

Terminal dark theme: base `#0A0A0A`, surface `#151A26`, accent `#EF4444`, JetBrains Mono, ionicons, soft 3D shadows on rounded buttons. All visual tokens live in `lib/theme.dart`; screens read tokens, never hardcode values. The signature element is the terminal status console (`bexxcord://session`) that renders the live state machine, pipeline, fps, dropped frames, thermal status and audio source exactly as the Kotlin engine reports them.
