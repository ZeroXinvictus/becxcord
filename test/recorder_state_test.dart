import 'package:flutter_test/flutter_test.dart';
import 'package:bexxcord/services/recorder_service.dart';

void main() {
  group('RecorderState.fromMap', () {
    test('parses idle state without fields', () {
      final state = RecorderState.fromMap({'state': 'idle'});
      expect(state, isA<RecorderStateIdle>());
    });

    test('unknown state kinds fall back to idle instead of throwing', () {
      final state = RecorderState.fromMap({'state': 'warp_speed'});
      expect(state, isA<RecorderStateIdle>());
    });

    test('parses recording state with every field typed', () {
      final state = RecorderState.fromMap({
        'state': 'recording',
        'startedAtEpochMs': 1700000000000,
        'elapsedMs': 45000,
        'fps': 29.97,
        'droppedFrames': 3,
        'segmentCount': 2,
        'audioSource': 'sys',
      });
      final recording = state as RecorderStateRecording;
      expect(recording.startedAtEpochMs, 1700000000000);
      expect(recording.elapsedMs, 45000);
      expect(recording.fps, closeTo(29.97, 0.001));
      expect(recording.droppedFrames, 3);
      expect(recording.segmentCount, 2);
      expect(recording.audioSource, 'sys');
    });

    test('recording state applies defaults when fields are missing', () {
      final state = RecorderState.fromMap({'state': 'recording'});
      final recording = state as RecorderStateRecording;
      expect(recording.elapsedMs, 0);
      expect(recording.fps, 0);
      expect(recording.segmentCount, 1);
      expect(recording.audioSource, 'mute');
    });

    test('parses paused state', () {
      final state = RecorderState.fromMap({
        'state': 'paused',
        'startedAtEpochMs': 1700000000000,
        'elapsedMs': 12000,
        'droppedFrames': 1,
        'segmentCount': 1,
        'audioSource': 'mic',
      });
      final paused = state as RecorderStatePaused;
      expect(paused.elapsedMs, 12000);
      expect(paused.audioSource, 'mic');
    });

    test('parses saved state with codec and audio tags', () {
      final state = RecorderState.fromMap({
        'state': 'saved',
        'uri': 'content://media/external/video/media/42',
        'durationMs': 90000,
        'sizeBytes': 123456789,
        'width': 1080,
        'height': 2400,
        'fps': 60,
        'codecTag': 'h265',
        'audioTag': 'sys',
        'segmentCount': 3,
      });
      final saved = state as RecorderStateSaved;
      expect(saved.uri, 'content://media/external/video/media/42');
      expect(saved.durationMs, 90000);
      expect(saved.sizeBytes, 123456789);
      expect(saved.width, 1080);
      expect(saved.height, 2400);
      expect(saved.fps, 60);
      expect(saved.codecTag, 'h265');
      expect(saved.audioTag, 'sys');
      expect(saved.segmentCount, 3);
    });

    test('parses error state with recoverable flag', () {
      final state = RecorderState.fromMap({
        'state': 'error',
        'code': 'STORAGE_LOW',
        'message': 'free storage below reserve',
        'recoverable': true,
      });
      final error = state as RecorderStateError;
      expect(error.code, 'STORAGE_LOW');
      expect(error.recoverable, isTrue);
    });

    test('parses interrupted state reason', () {
      final state = RecorderState.fromMap({'state': 'interrupted', 'reason': 'projection_stopped'});
      final interrupted = state as RecorderStateInterrupted;
      expect(interrupted.reason, 'projection_stopped');
    });

    test('parses stopping and finalizing states', () {
      final stopping = RecorderState.fromMap({'state': 'stopping', 'elapsedMs': 5000});
      expect((stopping as RecorderStateStopping).elapsedMs, 5000);
      final finalizing = RecorderState.fromMap({'state': 'finalizing', 'segmentCount': 4});
      expect((finalizing as RecorderStateFinalizing).segmentCount, 4);
    });

    test('parses preparing and starting profile labels', () {
      final preparing = RecorderState.fromMap({'state': 'preparing', 'profileLabel': '1080x2400@60 h265'});
      expect((preparing as RecorderStatePreparing).profileLabel, '1080x2400@60 h265');
      final starting = RecorderState.fromMap({'state': 'starting', 'profileLabel': '720p'});
      expect((starting as RecorderStateStarting).profileLabel, '720p');
    });
  });

  group('RecorderTelemetry.fromMap', () {
    test('parses every telemetry field', () {
      final telemetry = RecorderTelemetry.fromMap({
        'fps': 58.5,
        'droppedFrames': 7,
        'thermalStatus': 2,
        'thermalHeadroom': 4.2,
        'elapsedMs': 65000,
        'segmentCount': 2,
        'activePipeline': 'MediaCodec+MediaMuxer',
        'audioSource': 'mic',
      });
      expect(telemetry.fps, closeTo(58.5, 0.001));
      expect(telemetry.droppedFrames, 7);
      expect(telemetry.thermalStatus, 2);
      expect(telemetry.thermalHeadroom, closeTo(4.2, 0.001));
      expect(telemetry.elapsedMs, 65000);
      expect(telemetry.segmentCount, 2);
      expect(telemetry.activePipeline, 'MediaCodec+MediaMuxer');
      expect(telemetry.audioSource, 'mic');
      expect(telemetry.thermalLabel, 'MODERATE');
    });

    test('thermal headroom is null when device does not expose it', () {
      final telemetry = RecorderTelemetry.fromMap({'fps': 30.0});
      expect(telemetry.thermalHeadroom, isNull);
      expect(telemetry.thermalLabel, 'NONE');
    });
  });

  group('Capabilities.fromMap', () {
    test('parses capability matrix including free storage', () {
      final capabilities = Capabilities.fromMap({
        'apiLevel': 34,
        'mediaProjectionSupported': true,
        'displayWidth': 1080,
        'displayHeight': 2400,
        'displayRefreshRate': 120,
        'h264Encoder': 'OMX.qcom.video.encoder.avc',
        'h265Encoder': 'OMX.qcom.video.encoder.hevc',
        'maxVideoBitrateBps': 120000000,
        'systemPlaybackSupported': true,
        'systemPlaybackUnavailableReason': null,
        'microphoneSupported': true,
        'overlayPermissionGranted': true,
        'notificationPermissionGranted': true,
        'thermalStatusSupported': true,
        'thermalHeadroomSupported': true,
        'freeStorageBytes': 53687091200,
        'pipeline': 'MediaCodec+MediaMuxer',
      });
      expect(capabilities.apiLevel, 34);
      expect(capabilities.displayWidth, 1080);
      expect(capabilities.displayRefreshRate, 120);
      expect(capabilities.h265Encoder, isNotNull);
      expect(capabilities.systemPlaybackSupported, isTrue);
      expect(capabilities.freeStorageBytes, 53687091200);
      expect(capabilities.pipeline, 'MediaCodec+MediaMuxer');
    });

    test('free storage defaults to zero when probing fails', () {
      final capabilities = Capabilities.fromMap({});
      expect(capabilities.freeStorageBytes, 0);
      expect(capabilities.mediaProjectionSupported, isFalse);
    });
  });

  group('RecordingConfig.toMap', () {
    test('serializes to the typed channel contract', () {
      const config = RecordingConfig(
        width: 1080,
        height: 2400,
        fps: 60,
        videoBitrateBps: 12000000,
        audioBitrateBps: 128000,
        codec: 'h265',
        micEnabled: false,
        systemAudioEnabled: true,
      );
      final map = config.toMap();
      expect(map['width'], 1080);
      expect(map['height'], 2400);
      expect(map['fps'], 60);
      expect(map['videoBitrateBps'], 12000000);
      expect(map['audioBitrateBps'], 128000);
      expect(map['codec'], 'h265');
      expect(map['micEnabled'], isFalse);
      expect(map['systemAudioEnabled'], isTrue);
    });
  });

  group('RecordingEntry.fromMap', () {
    test('parses library entry from media store query', () {
      final entry = RecordingEntry.fromMap({
        'uri': 'content://media/external/video/media/7',
        'title': 'BexxCord_20260101_120000',
        'durationMs': 60000,
        'sizeBytes': 50000000,
        'width': 1080,
        'height': 2400,
        'createdAtMs': 1767225600000,
        'codecTag': 'h264',
        'audioTag': 'mute',
      });
      expect(entry.title, 'BexxCord_20260101_120000');
      expect(entry.durationMs, 60000);
      expect(entry.sizeBytes, 50000000);
      expect(entry.codecTag, 'h264');
      expect(entry.audioTag, 'mute');
    });

    test('library entry applies honest defaults for missing metadata', () {
      final entry = RecordingEntry.fromMap({});
      expect(entry.title, 'recording');
      expect(entry.durationMs, 0);
      expect(entry.codecTag, 'h264');
      expect(entry.audioTag, 'mute');
    });
  });
}
