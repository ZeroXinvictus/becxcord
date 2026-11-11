import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

sealed class RecorderState {
  const RecorderState();

  factory RecorderState.fromMap(Map<Object?, Object?> map) {
    final kind = map['state'] as String? ?? 'idle';
    return switch (kind) {
      'preparing' => RecorderStatePreparing(map['profileLabel'] as String? ?? ''),
      'requestingPermission' =>
        RecorderStateRequestingPermission(map['permission'] as String? ?? ''),
      'starting' => RecorderStateStarting(map['profileLabel'] as String? ?? ''),
      'recording' => RecorderStateRecording(
        startedAtEpochMs: map['startedAtEpochMs'] as int? ?? 0,
        elapsedMs: map['elapsedMs'] as int? ?? 0,
        fps: (map['fps'] as num?)?.toDouble() ?? 0,
        droppedFrames: map['droppedFrames'] as int? ?? 0,
        segmentCount: map['segmentCount'] as int? ?? 1,
        audioSource: map['audioSource'] as String? ?? 'mute',
      ),
      'paused' => RecorderStatePaused(
        startedAtEpochMs: map['startedAtEpochMs'] as int? ?? 0,
        elapsedMs: map['elapsedMs'] as int? ?? 0,
        droppedFrames: map['droppedFrames'] as int? ?? 0,
        segmentCount: map['segmentCount'] as int? ?? 1,
        audioSource: map['audioSource'] as String? ?? 'mute',
      ),
      'stopping' => RecorderStateStopping(map['elapsedMs'] as int? ?? 0),
      'finalizing' => RecorderStateFinalizing(map['segmentCount'] as int? ?? 0),
      'saved' => RecorderStateSaved(
        uri: map['uri'] as String? ?? '',
        durationMs: map['durationMs'] as int? ?? 0,
        sizeBytes: map['sizeBytes'] as int? ?? 0,
        width: map['width'] as int? ?? 0,
        height: map['height'] as int? ?? 0,
        fps: map['fps'] as int? ?? 0,
        codecTag: map['codecTag'] as String? ?? 'h264',
        audioTag: map['audioTag'] as String? ?? 'mute',
        segmentCount: map['segmentCount'] as int? ?? 1,
      ),
      'error' => RecorderStateError(
        code: map['code'] as String? ?? 'UNKNOWN',
        message: map['message'] as String? ?? '',
        recoverable: map['recoverable'] as bool? ?? false,
      ),
      'interrupted' => RecorderStateInterrupted(map['reason'] as String? ?? ''),
      _ => const RecorderStateIdle(),
    };
  }
}

final class RecorderStateIdle extends RecorderState {
  const RecorderStateIdle();
}

final class RecorderStatePreparing extends RecorderState {
  const RecorderStatePreparing(this.profileLabel);

  final String profileLabel;
}

final class RecorderStateRequestingPermission extends RecorderState {
  const RecorderStateRequestingPermission(this.permission);

  final String permission;
}

final class RecorderStateStarting extends RecorderState {
  const RecorderStateStarting(this.profileLabel);

  final String profileLabel;
}

final class RecorderStateRecording extends RecorderState {
  const RecorderStateRecording({
    required this.startedAtEpochMs,
    required this.elapsedMs,
    required this.fps,
    required this.droppedFrames,
    required this.segmentCount,
    required this.audioSource,
  });

  final int startedAtEpochMs;
  final int elapsedMs;
  final double fps;
  final int droppedFrames;
  final int segmentCount;
  final String audioSource;
}

final class RecorderStatePaused extends RecorderState {
  const RecorderStatePaused({
    required this.startedAtEpochMs,
    required this.elapsedMs,
    required this.droppedFrames,
    required this.segmentCount,
    required this.audioSource,
  });

  final int startedAtEpochMs;
  final int elapsedMs;
  final int droppedFrames;
  final int segmentCount;
  final String audioSource;
}

final class RecorderStateStopping extends RecorderState {
  const RecorderStateStopping(this.elapsedMs);

  final int elapsedMs;
}

final class RecorderStateFinalizing extends RecorderState {
  const RecorderStateFinalizing(this.segmentCount);

  final int segmentCount;
}

final class RecorderStateSaved extends RecorderState {
  const RecorderStateSaved({
    required this.uri,
    required this.durationMs,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.fps,
    required this.codecTag,
    required this.audioTag,
    required this.segmentCount,
  });

  final String uri;
  final int durationMs;
  final int sizeBytes;
  final int width;
  final int height;
  final int fps;
  final String codecTag;
  final String audioTag;
  final int segmentCount;
}

final class RecorderStateError extends RecorderState {
  const RecorderStateError({
    required this.code,
    required this.message,
    required this.recoverable,
  });

  final String code;
  final String message;
  final bool recoverable;
}

final class RecorderStateInterrupted extends RecorderState {
  const RecorderStateInterrupted(this.reason);

  final String reason;
}

final class RecorderTelemetry {
  const RecorderTelemetry({
    required this.fps,
    required this.droppedFrames,
    required this.thermalStatus,
    required this.thermalHeadroom,
    required this.elapsedMs,
    required this.segmentCount,
    required this.activePipeline,
    required this.audioSource,
  });

  factory RecorderTelemetry.fromMap(Map<Object?, Object?> map) => RecorderTelemetry(
        fps: (map['fps'] as num?)?.toDouble() ?? 0,
        droppedFrames: map['droppedFrames'] as int? ?? 0,
        thermalStatus: map['thermalStatus'] as int? ?? 0,
        thermalHeadroom: (map['thermalHeadroom'] as num?)?.toDouble(),
        elapsedMs: map['elapsedMs'] as int? ?? 0,
        segmentCount: map['segmentCount'] as int? ?? 0,
        activePipeline: map['activePipeline'] as String? ?? 'MediaCodec+MediaMuxer',
        audioSource: map['audioSource'] as String? ?? 'mute',
      );

  final double fps;
  final int droppedFrames;
  final int thermalStatus;
  final double? thermalHeadroom;
  final int elapsedMs;
  final int segmentCount;
  final String activePipeline;
  final String audioSource;

  String get thermalLabel => switch (thermalStatus) {
        0 => 'NONE',
        1 => 'LIGHT',
        2 => 'MODERATE',
        3 => 'SEVERE',
        4 => 'CRITICAL',
        5 => 'EMERGENCY',
        6 => 'SHUTDOWN',
        _ => 'UNKNOWN',
      };
}

final class Capabilities {
  const Capabilities({
    required this.apiLevel,
    required this.mediaProjectionSupported,
    required this.displayWidth,
    required this.displayHeight,
    required this.displayRefreshRate,
    required this.h264Encoder,
    required this.h265Encoder,
    required this.maxVideoBitrateBps,
    required this.systemPlaybackSupported,
    required this.systemPlaybackUnavailableReason,
    required this.microphoneSupported,
    required this.overlayPermissionGranted,
    required this.notificationPermissionGranted,
    required this.thermalStatusSupported,
    required this.thermalHeadroomSupported,
    required this.freeStorageBytes,
    required this.pipeline,
  });

  factory Capabilities.fromMap(Map<Object?, Object?> map) => Capabilities(
        apiLevel: map['apiLevel'] as int? ?? 0,
        mediaProjectionSupported: map['mediaProjectionSupported'] as bool? ?? false,
        displayWidth: map['displayWidth'] as int? ?? 0,
        displayHeight: map['displayHeight'] as int? ?? 0,
        displayRefreshRate: map['displayRefreshRate'] as int? ?? 60,
        h264Encoder: map['h264Encoder'] as String?,
        h265Encoder: map['h265Encoder'] as String?,
        maxVideoBitrateBps: map['maxVideoBitrateBps'] as int? ?? 0,
        systemPlaybackSupported: map['systemPlaybackSupported'] as bool? ?? false,
        systemPlaybackUnavailableReason: map['systemPlaybackUnavailableReason'] as String?,
        microphoneSupported: map['microphoneSupported'] as bool? ?? false,
        overlayPermissionGranted: map['overlayPermissionGranted'] as bool? ?? false,
        notificationPermissionGranted: map['notificationPermissionGranted'] as bool? ?? false,
        thermalStatusSupported: map['thermalStatusSupported'] as bool? ?? false,
        thermalHeadroomSupported: map['thermalHeadroomSupported'] as bool? ?? false,
        freeStorageBytes: map['freeStorageBytes'] as int? ?? 0,
        pipeline: map['pipeline'] as String? ?? 'MediaCodec+MediaMuxer',
      );

  final int apiLevel;
  final bool mediaProjectionSupported;
  final int displayWidth;
  final int displayHeight;
  final int displayRefreshRate;
  final String? h264Encoder;
  final String? h265Encoder;
  final int maxVideoBitrateBps;
  final bool systemPlaybackSupported;
  final String? systemPlaybackUnavailableReason;
  final bool microphoneSupported;
  final bool overlayPermissionGranted;
  final bool notificationPermissionGranted;
  final bool thermalStatusSupported;
  final bool thermalHeadroomSupported;
  final int freeStorageBytes;
  final String pipeline;
}

final class RecordingConfig {
  const RecordingConfig({
    required this.width,
    required this.height,
    required this.fps,
    required this.videoBitrateBps,
    required this.audioBitrateBps,
    required this.codec,
    required this.micEnabled,
    required this.systemAudioEnabled,
  });

  Map<String, Object> toMap() => {
        'width': width,
        'height': height,
        'fps': fps,
        'videoBitrateBps': videoBitrateBps,
        'audioBitrateBps': audioBitrateBps,
        'codec': codec,
        'micEnabled': micEnabled,
        'systemAudioEnabled': systemAudioEnabled,
      };

  final int width;
  final int height;
  final int fps;
  final int videoBitrateBps;
  final int audioBitrateBps;
  final String codec;
  final bool micEnabled;
  final bool systemAudioEnabled;
}

final class RecordingEntry {
  const RecordingEntry({
    required this.uri,
    required this.title,
    required this.durationMs,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.createdAtMs,
    required this.codecTag,
    required this.audioTag,
  });

  factory RecordingEntry.fromMap(Map<Object?, Object?> map) => RecordingEntry(
        uri: map['uri'] as String? ?? '',
        title: map['title'] as String? ?? 'recording',
        durationMs: map['durationMs'] as int? ?? 0,
        sizeBytes: map['sizeBytes'] as int? ?? 0,
        width: map['width'] as int? ?? 0,
        height: map['height'] as int? ?? 0,
        createdAtMs: map['createdAtMs'] as int? ?? 0,
        codecTag: map['codecTag'] as String? ?? 'h264',
        audioTag: map['audioTag'] as String? ?? 'mute',
      );

  final String uri;
  final String title;
  final int durationMs;
  final int sizeBytes;
  final int width;
  final int height;
  final int createdAtMs;
  final String codecTag;
  final String audioTag;
}

final class StartOutcome {
  const StartOutcome({required this.accepted, this.errorCode, this.errorMessage});

  final bool accepted;
  final String? errorCode;
  final String? errorMessage;
}

final class PreferenceOutcome {
  const PreferenceOutcome({required this.applied, this.errorCode});

  final bool applied;
  final String? errorCode;
}

final class FrameCaptureOutcome {
  const FrameCaptureOutcome({required this.saved, this.uri, this.width, this.height});

  final bool saved;
  final String? uri;
  final int? width;
  final int? height;
}

class RecorderController extends ChangeNotifier {
  static const MethodChannel _method = MethodChannel('bexxcord/recorder');
  static const EventChannel _stateChannel = EventChannel('bexxcord/state');
  static const EventChannel _telemetryChannel = EventChannel('bexxcord/telemetry');
  static const EventChannel _errorChannel = EventChannel('bexxcord/errors');

  RecorderState _state = const RecorderStateIdle();
  RecorderTelemetry? _telemetry;
  Capabilities? _capabilities;
  List<RecordingEntry> _recordings = const [];
  bool _micEnabled = true;
  bool _systemAudioEnabled = true;
  bool _countdownEnabled = true;
  bool _projectionReady = false;
  String? _lastError;
  final Map<String, Uint8List?> _thumbnailCache = {};

  RecorderState get state => _state;
  RecorderTelemetry? get telemetry => _telemetry;
  Capabilities? get capabilities => _capabilities;
  List<RecordingEntry> get recordings => _recordings;
  bool get micEnabled => _micEnabled;
  bool get systemAudioEnabled => _systemAudioEnabled;
  bool get countdownEnabled => _countdownEnabled;
  bool get projectionReady => _projectionReady;
  String? get lastError => _lastError;

  StreamSubscription<Object?>? _stateSub;
  StreamSubscription<Object?>? _telemetrySub;
  StreamSubscription<Object?>? _errorSub;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _stateSub = _stateChannel.receiveBroadcastStream().listen(_onStateEvent);
    _telemetrySub = _telemetryChannel.receiveBroadcastStream().listen(_onTelemetryEvent);
    _errorSub = _errorChannel.receiveBroadcastStream().listen(_onErrorEvent);
    await _method.invokeMethod<void>('requestRuntimePermissions');
    await reloadAll();
  }

  Future<void> reloadAll() async {
    final capabilitiesMap =
        await _method.invokeMethod<Map<Object?, Object?>>('getCapabilities');
    if (capabilitiesMap != null) {
      _capabilities = Capabilities.fromMap(capabilitiesMap);
    }
    final preferencesMap =
        await _method.invokeMethod<Map<Object?, Object?>>('getPreferences');
    if (preferencesMap != null) {
      _micEnabled = preferencesMap['micEnabled'] as bool? ?? true;
      _systemAudioEnabled = preferencesMap['systemAudioEnabled'] as bool? ?? true;
      _countdownEnabled = preferencesMap['countdownEnabled'] as bool? ?? true;
    }
    await refreshRecordings();
    notifyListeners();
  }

  Future<void> refreshRecordings() async {
    final raw = await _method.invokeMethod<List<Object?>>('getRecordings');
    if (raw != null) {
      _recordings = raw
          .map((item) => RecordingEntry.fromMap(Map<Object?, Object?>.from(item as Map)))
          .toList();
      notifyListeners();
    }
  }

  Future<bool> requestProjection() async {
    final result = await _method.invokeMethod<Map<Object?, Object?>>('requestProjection');
    final granted = result?['granted'] == true;
    _projectionReady = granted;
    if (!granted) {
      _lastError = 'Capture consent denied by user or system';
    }
    notifyListeners();
    return granted;
  }

  Future<StartOutcome> startRecording(RecordingConfig config) async {
    final result = await _method.invokeMethod<Map<Object?, Object?>>(
      'startRecording',
      config.toMap(),
    );
    if (result == null) {
      return const StartOutcome(accepted: false, errorCode: 'CHANNEL_ERROR');
    }
    final accepted = result['accepted'] == true;
    if (accepted) {
      _projectionReady = false;
      _lastError = null;
    } else {
      _lastError = result['errorMessage'] as String? ??
          result['errorCode'] as String? ??
          'start rejected';
    }
    notifyListeners();
    return StartOutcome(
      accepted: accepted,
      errorCode: result['errorCode'] as String?,
      errorMessage: result['errorMessage'] as String?,
    );
  }

  Future<void> pauseRecording() async {
    await _method.invokeMethod<void>('pauseRecording');
  }

  Future<void> resumeRecording() async {
    await _method.invokeMethod<void>('resumeRecording');
  }

  Future<void> stopRecording() async {
    await _method.invokeMethod<void>('stopRecording');
  }

  Future<PreferenceOutcome> setMicEnabled(bool value) async {
    final result = await _method.invokeMethod<Map<Object?, Object?>>(
      'setMicEnabled',
      value,
    );
    final applied = result?['applied'] == true;
    if (applied) {
      _micEnabled = value;
    } else {
      _lastError = result?['errorCode'] as String? ?? 'mic preference rejected';
    }
    notifyListeners();
    return PreferenceOutcome(applied: applied, errorCode: result?['errorCode'] as String?);
  }

  Future<PreferenceOutcome> setSystemAudioEnabled(bool value) async {
    final result = await _method.invokeMethod<Map<Object?, Object?>>(
      'setSystemAudioEnabled',
      value,
    );
    final applied = result?['applied'] == true;
    if (applied) {
      _systemAudioEnabled = value;
    } else {
      _lastError = result?['errorCode'] as String? ?? 'system audio preference rejected';
    }
    notifyListeners();
    return PreferenceOutcome(applied: applied, errorCode: result?['errorCode'] as String?);
  }

  Future<void> saveProfile(RecordingConfig config) async {
    await _method.invokeMethod<void>('saveProfile', config.toMap());
  }

  Future<void> setCountdownEnabled(bool value) async {
    _countdownEnabled = value;
    await _method.invokeMethod<void>('setCountdownEnabled', value);
    notifyListeners();
  }

  Future<Uint8List?> thumbnailFor(String uri) async {
    if (_thumbnailCache.containsKey(uri)) return _thumbnailCache[uri];
    Uint8List? bytes;
    try {
      bytes = await _method.invokeMethod<Uint8List>('getRecordingThumbnail', uri);
    } on PlatformException {
      bytes = null;
    }
    _thumbnailCache[uri] = bytes;
    return bytes;
  }

  Future<FrameCaptureOutcome> captureFrame(String uri, int positionMs) async {
    try {
      final result = await _method.invokeMethod<Map<Object?, Object?>>('captureFrame', {
        'uri': uri,
        'positionMs': positionMs,
      });
      if (result == null) return const FrameCaptureOutcome(saved: false);
      return FrameCaptureOutcome(
        saved: true,
        uri: result['uri'] as String?,
        width: result['width'] as int?,
        height: result['height'] as int?,
      );
    } on PlatformException {
      return const FrameCaptureOutcome(saved: false);
    }
  }

  Future<bool> deleteRecording(RecordingEntry entry) async {
    final deleted = await _method.invokeMethod<bool>('deleteRecording', entry.uri) ?? false;
    if (deleted) {
      _thumbnailCache.remove(entry.uri);
      await refreshRecordings();
    }
    return deleted;
  }

  Future<bool> renameRecording(RecordingEntry entry, String newTitle) async {
    final renamed = await _method.invokeMethod<bool>('renameRecording', {
      'uri': entry.uri,
      'title': newTitle,
    }) ?? false;
    if (renamed) {
      await refreshRecordings();
    }
    return renamed;
  }

  Future<void> openOverlaySettings() async {
    await _method.invokeMethod<void>('openOverlaySettings');
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  void _onStateEvent(Object? event) {
    if (event is! Map) return;
    _state = RecorderState.fromMap(Map<Object?, Object?>.from(event));
    notifyListeners();
  }

  void _onTelemetryEvent(Object? event) {
    if (event is! Map) return;
    _telemetry = RecorderTelemetry.fromMap(Map<Object?, Object?>.from(event));
    notifyListeners();
  }

  void _onErrorEvent(Object? event) {
    if (event is! Map) return;
    final map = Map<Object?, Object?>.from(event);
    _lastError = map['message'] as String? ?? map['code'] as String? ?? 'unknown error';
    notifyListeners();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _telemetrySub?.cancel();
    _errorSub?.cancel();
    super.dispose();
  }
}
