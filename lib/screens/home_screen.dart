import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ionicons/ionicons.dart';

import '../main.dart';
import '../services/recorder_service.dart';
import '../theme.dart';
import '../widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _resolutionIndex = 0;
  int _fpsIndex = 0;
  int _codecIndex = 0;
  int _bitrateIndex = 1;
  bool _micEnabled = true;
  bool _systemAudioEnabled = true;

  static const List<int> _fpsOptions = [24, 30, 60];
  static const List<int> _bitrateMbpsOptions = [6, 12, 20, 30];

  bool _prefsSynced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefsSynced) return;
    _prefsSynced = true;
    final controller = RecorderScope.of(context);
    _micEnabled = controller.micEnabled;
    _systemAudioEnabled = controller.systemAudioEnabled;
    final capabilities = controller.capabilities;
    if (capabilities != null && capabilities.h265Encoder == null && _codecIndex > 0) {
      _codecIndex = 0;
    }
  }

  List<ResolutionOption> _resolutionOptions(Capabilities capabilities) {
    final maxW = capabilities.displayWidth;
    final maxH = capabilities.displayHeight;
    final candidates = <ResolutionOption>[
      ResolutionOption(1920, 1080),
      ResolutionOption(1280, 720),
      ResolutionOption(854, 480),
    ];
    if (maxW >= capabilities.displayWidth && maxH >= capabilities.displayHeight) {
      candidates.insert(
        0,
        ResolutionOption(capabilities.displayWidth, capabilities.displayHeight),
      );
    }
    final filtered = candidates
        .where((option) => maxW <= 0 || (option.width <= maxW && option.height <= maxH))
        .toList();
    if (filtered.isEmpty) {
      filtered.add(const ResolutionOption(1280, 720));
    }
    return filtered;
  }

  List<CodecOption> _codecOptions(Capabilities capabilities) {
    final options = <CodecOption>[const CodecOption('h264', 'H264')];
    if (capabilities.h265Encoder != null) {
      options.add(const CodecOption('h265', 'H265'));
    }
    return options;
  }

  @override
  Widget build(BuildContext context) {
    final controller = RecorderScope.of(context);
    final state = controller.state;
    final telemetry = controller.telemetry;
    final capabilities = controller.capabilities;

    if (capabilities == null) {
      return const Scaffold(
        body: Center(
          child: TerminalPanel(
            busy: true,
            lines: [
              StatusLineData('boot', 'probing capability matrix'),
            ],
          ),
        ),
      );
    }

    final resolutions = _resolutionOptions(capabilities);
    if (_resolutionIndex >= resolutions.length) _resolutionIndex = 0;
    final codecs = _codecOptions(capabilities);
    if (_codecIndex >= codecs.length) _codecIndex = 0;
    final resolution = resolutions[_resolutionIndex];
    final codec = codecs[_codecIndex];
    final fpsOptions = _fpsOptions
        .where((option) => capabilities.displayRefreshRate <= 0 || option <= capabilities.displayRefreshRate)
        .toList();
    if (fpsOptions.isEmpty) fpsOptions.add(30);
    if (_fpsIndex >= fpsOptions.length) _fpsIndex = 0;
    final fps = fpsOptions[_fpsIndex];
    final bitrateMbps = _bitrateMbpsOptions[_bitrateIndex];

    final config = RecordingConfig(
      width: resolution.width,
      height: resolution.height,
      fps: fps,
      videoBitrateBps: bitrateMbps * 1000000,
      audioBitrateBps: 128000,
      codec: codec.tag,
      micEnabled: _micEnabled,
      systemAudioEnabled: _systemAudioEnabled,
    );

    final isRecording = state is RecorderStateRecording;
    final isPaused = state is RecorderStatePaused;
    final isActive = isRecording || isPaused;
    final busyStarting = state is RecorderStatePreparing ||
        state is RecorderStateStarting ||
        state is RecorderStateStopping ||
        state is RecorderStateFinalizing;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _buildTopBar(context),
            const SizedBox(height: AppSpacing.md),
            TerminalPanel(
              busy: isRecording || isPaused || busyStarting,
              lines: _terminalLines(state, telemetry, capabilities),
            ),
            const SizedBox(height: AppSpacing.md),
            _buildCapabilityChips(context, controller, capabilities),
            const SizedBox(height: AppSpacing.md),
            if (controller.lastError != null) ...[
              ErrorBanner(
                message: controller.lastError!,
                onDismiss: controller.clearError,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (state is RecorderStateSaved) _buildSavedCard(state),
            if (state is RecorderStateError)
              _buildErrorCard(state)
            else if (state is RecorderStateInterrupted)
              _buildInterruptedCard(state)
            else if (!isActive && !busyStarting)
              _buildConfigSection(capabilities, controller),
            const SizedBox(height: AppSpacing.md),
            _buildPrimaryActions(
              context,
              controller,
              config,
              isActive: isActive,
              isRecording: isRecording,
              isPaused: isPaused,
              busy: busyStarting,
            ),
            const SizedBox(height: AppSpacing.lg),
            _buildRecentRecordings(context, controller),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(color: AppColors.line),
          ),
          child: Center(
            child: Text(
              'BX',
              style: AppText.mono(size: 14, weight: FontWeight.w800, color: AppColors.accent),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'BexxCord',
              style: AppText.mono(size: 18, weight: FontWeight.w800, spacing: 1),
            ),
            Text(
              'screen + audio recorder',
              style: AppText.mono(size: 10, color: AppColors.textMuted),
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Open library',
          icon: const Icon(Ionicons.folderOpenOutline, color: AppColors.textMuted),
          onPressed: () => Navigator.of(context).pushNamed('/library'),
        ),
      ],
    );
  }

  List<StatusLineData> _terminalLines(
    RecorderState state,
    RecorderTelemetry? telemetry,
    Capabilities capabilities,
  ) {
    final stateLabel = switch (state) {
      RecorderStateIdle() => 'IDLE',
      RecorderStatePreparing() => 'PREPARING',
      RecorderStateRequestingPermission() => 'AWAITING CONSENT',
      RecorderStateStarting() => 'STARTING',
      RecorderStateRecording() => 'RECORDING',
      RecorderStatePaused() => 'PAUSED',
      RecorderStateStopping() => 'STOPPING',
      RecorderStateFinalizing() => 'FINALIZING',
      RecorderStateSaved() => 'SAVED',
      RecorderStateError() => 'ERROR',
      RecorderStateInterrupted() => 'INTERRUPTED',
    };
    final stateColor = switch (state) {
      RecorderStateRecording() => AppColors.accent,
      RecorderStatePaused() => AppColors.warn,
      RecorderStateError() || RecorderStateInterrupted() => AppColors.accent,
      RecorderStateSaved() => AppColors.ok,
      _ => AppColors.textPrimary,
    };
    return [
      StatusLineData('STATE', stateLabel, color: stateColor),
      StatusLineData('PIPELINE', capabilities.pipeline),
      StatusLineData('FPS', telemetry == null ? '--' : telemetry.fps.toStringAsFixed(1)),
      StatusLineData(
        'DROPPED',
        telemetry == null ? '--' : telemetry.droppedFrames.toString(),
      ),
      StatusLineData(
        'THERMAL',
        telemetry == null
            ? (capabilities.thermalStatusSupported ? 'pending' : 'unsupported')
            : '${telemetry.thermalLabel}${telemetry.thermalHeadroom == null ? '' : ' (${telemetry.thermalHeadroom!.toStringAsFixed(1)})'}',
      ),
      StatusLineData(
        'ELAPSED',
        _formatDuration(
          telemetry?.elapsedMs ??
              switch (state) {
                RecorderStateRecording(:final elapsedMs) => elapsedMs,
                RecorderStatePaused(:final elapsedMs) => elapsedMs,
                RecorderStateStopping(:final elapsedMs) => elapsedMs,
                _ => 0,
              },
        ),
      ),
      StatusLineData(
        'AUDIO',
        switch (state) {
          RecorderStateRecording(:final audioSource) => audioSource,
          RecorderStatePaused(:final audioSource) => audioSource,
          _ => (telemetry?.audioSource ?? 'mute'),
        },
      ),
    ];
  }

  Widget _buildCapabilityChips(
    BuildContext context,
    RecorderController controller,
    Capabilities capabilities,
  ) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        CapabilityChip(
          icon: Ionicons.hardwareChipOutline,
          label: 'API',
          value: '${capabilities.apiLevel}',
          state: CapabilityState.ok,
        ),
        CapabilityChip(
          icon: Ionicons.videocamOutline,
          label: 'H264',
          value: capabilities.h264Encoder != null ? 'HW' : 'missing',
          state: capabilities.h264Encoder != null ? CapabilityState.ok : CapabilityState.off,
        ),
        CapabilityChip(
          icon: Ionicons.filmOutline,
          label: 'H265',
          value: capabilities.h265Encoder != null ? 'HW' : 'n/a',
          state: capabilities.h265Encoder != null ? CapabilityState.ok : CapabilityState.off,
        ),
        CapabilityChip(
          icon: Ionicons.volumeHighOutline,
          label: 'SYS AUDIO',
          value: capabilities.systemPlaybackSupported ? 'capture' : 'n/a',
          state: capabilities.systemPlaybackSupported ? CapabilityState.ok : CapabilityState.off,
        ),
        CapabilityChip(
          icon: Ionicons.micOutline,
          label: 'MIC',
          value: capabilities.microphoneSupported ? 'ready' : 'missing',
          state: capabilities.microphoneSupported ? CapabilityState.ok : CapabilityState.off,
        ),
        CapabilityChip(
          icon: Ionicons.phonePortraitOutline,
          label: 'OVERLAY',
          value: capabilities.overlayPermissionGranted ? 'granted' : 'off',
          state: capabilities.overlayPermissionGranted ? CapabilityState.ok : CapabilityState.warn,
          onTap: capabilities.overlayPermissionGranted ? null : controller.openOverlaySettings,
        ),
        CapabilityChip(
          icon: Ionicons.notificationsOutline,
          label: 'NOTIFY',
          value: capabilities.notificationPermissionGranted ? 'granted' : 'off',
          state: capabilities.notificationPermissionGranted ? CapabilityState.ok : CapabilityState.warn,
        ),
        CapabilityChip(
          icon: Ionicons.saveOutline,
          label: 'STORAGE',
          value: capabilities.freeStorageBytes <= 0
              ? 'unknown'
              : _formatBytes(capabilities.freeStorageBytes),
          state: capabilities.freeStorageBytes <= 0
              ? CapabilityState.off
              : CapabilityState.ok,
        ),
      ],
    );
  }

  Widget _buildConfigSection(Capabilities capabilities, RecorderController controller) {
    final resolutions = _resolutionOptions(capabilities);
    final codecs = _codecOptions(capabilities);
    final fpsOptions = _fpsOptions
        .where((option) =>
            capabilities.displayRefreshRate <= 0 ||
            option <= capabilities.displayRefreshRate)
        .toList();
    if (fpsOptions.isEmpty) fpsOptions.add(30);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(label: 'CAPTURE PROFILE'),
          _buildConfigDropdown(
            label: 'RESOLUTION',
            value: _resolutionIndex < resolutions.length
                ? '${resolutions[_resolutionIndex].width}x${resolutions[_resolutionIndex].height}'
                : 'custom',
            items: resolutions
                .map((option) => '${option.width}x${option.height}')
                .toList(),
            onChanged: (index) => setState(() => _resolutionIndex = index),
          ),
          _buildConfigDropdown(
            label: 'FRAME RATE',
            value: '${fpsOptions[_fpsIndex.clamp(0, fpsOptions.length - 1)]} FPS',
            items: fpsOptions.map((option) => '$option FPS').toList(),
            onChanged: (index) => setState(() => _fpsIndex = index),
          ),
          _buildConfigDropdown(
            label: 'CODEC',
            value: codecs[_codecIndex.clamp(0, codecs.length - 1)].label,
            items: codecs.map((option) => option.label).toList(),
            onChanged: (index) => setState(() => _codecIndex = index),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'VIDEO BITRATE',
            style: AppText.mono(size: 10, color: AppColors.textMuted, spacing: 1),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              for (final (index, mbps) in _bitrateMbpsOptions.indexed)
                _buildBitrateChip(mbps, index == _bitrateIndex),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _buildAudioToggle(
            icon: Ionicons.micOutline,
            label: 'MICROPHONE',
            value: _micEnabled,
            available: capabilities.microphoneSupported,
            onChanged: (value) async {
              final outcome = await controller.setMicEnabled(value);
              if (outcome.applied) setState(() => _micEnabled = value);
            },
          ),
          _buildAudioToggle(
            icon: Ionicons.volumeHighOutline,
            label: 'SYSTEM AUDIO',
            value: _systemAudioEnabled,
            available: capabilities.systemPlaybackSupported,
            reason: capabilities.systemPlaybackUnavailableReason,
            onChanged: (value) async {
              final outcome = await controller.setSystemAudioEnabled(value);
              if (outcome.applied) setState(() => _systemAudioEnabled = value);
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildCountdownToggle(controller),
        ],
      ),
    );
  }

  Widget _buildCountdownToggle(RecorderController controller) {
    return Row(
      children: [
        const Icon(Ionicons.timerOutline, size: 16, color: AppColors.textMuted),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('START COUNTDOWN', style: AppText.mono(size: 12)),
              Text(
                'three second countdown before the session begins',
                style: AppText.mono(size: 10, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        Switch(
          value: controller.countdownEnabled,
          onChanged: (value) {
            setState(() {});
            controller.setCountdownEnabled(value);
          },
        ),
      ],
    );
  }

  Widget _buildConfigDropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppText.mono(size: 10, color: AppColors.textMuted, spacing: 1),
          ),
          const SizedBox(height: AppSpacing.xs),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(color: AppColors.line),
            ),
            child: DropdownButtonHideUnderline(
              child: ButtonTheme(
                alignedDropdown: true,
                child: DropdownButton<String>(
                  value: value,
                  isExpanded: true,
                  icon: const Icon(
                    Ionicons.chevronDownOutline,
                    color: AppColors.textMuted,
                    size: 14,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  dropdownColor: AppColors.surface,
                  style: AppText.mono(size: 13),
                  items: [
                    for (final item in items)
                      DropdownMenuItem<String>(
                        value: item,
                        child: Text(item),
                      ),
                  ],
                  onChanged: (selection) {
                    final index = items.indexOf(selection ?? items.first);
                    if (index >= 0) onChanged(index);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBitrateChip(int mbps, bool selected) {
    return GestureDetector(
      onTap: () => setState(() => _bitrateIndex = _bitrateMbpsOptions.indexOf(mbps)),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(color: selected ? AppColors.accent : AppColors.line),
        ),
        child: Text(
          '${mbps}M',
          style: AppText.mono(
            size: 12,
            weight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildAudioToggle({
    required IconData icon,
    required String label,
    required bool value,
    required bool available,
    String? reason,
    required ValueChanged<bool> onChanged,
  }) {
    final enabled = available;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Row(
        children: [
          Icon(icon, size: 16, color: enabled ? AppColors.textMuted : AppColors.textFaint),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.mono(size: 12)),
                if (!enabled && reason != null)
                  Text(
                    reason,
                    style: AppText.mono(size: 10, color: AppColors.warn),
                  ),
              ],
            ),
          ),
          Switch(
            value: value && enabled,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryActions(
    BuildContext context,
    RecorderController controller,
    RecordingConfig config, {
    required bool isActive,
    required bool isRecording,
    required bool isPaused,
    required bool busy,
  }) {
    if (busy) {
      return const PrimaryAction(
        label: 'WORKING',
        icon: Ionicons.syncOutline,
        onTap: null,
        enabled: false,
        tone: ActionTone.neutral,
      );
    }
    if (isRecording) {
      return Column(
        children: [
          PrimaryAction(
            label: 'PAUSE',
            icon: Ionicons.pauseOutline,
            tone: ActionTone.neutral,
            onTap: controller.pauseRecording,
          ),
          const SizedBox(height: AppSpacing.sm),
          PrimaryAction(
            label: 'STOP',
            icon: Ionicons.stopOutline,
            tone: ActionTone.danger,
            onTap: controller.stopRecording,
          ),
        ],
      );
    }
    if (isPaused) {
      return Column(
        children: [
          PrimaryAction(
            label: 'RESUME',
            icon: Ionicons.playOutline,
            onTap: controller.resumeRecording,
          ),
          const SizedBox(height: AppSpacing.sm),
          PrimaryAction(
            label: 'STOP',
            icon: Ionicons.stopOutline,
            tone: ActionTone.danger,
            onTap: controller.stopRecording,
          ),
        ],
      );
    }
    return PrimaryAction(
      label: controller.projectionReady ? 'START RECORDING' : 'GRANT CAPTURE ACCESS',
      icon: controller.projectionReady
          ? Ionicons.recordingOutline
          : Ionicons.shieldCheckmarkOutline,
      onTap: () => _onStartTapped(controller, config),
    );
  }

  Future<void> _onStartTapped(RecorderController controller, RecordingConfig config) async {
    await controller.saveProfile(config);
    if (!controller.projectionReady) {
      final granted = await controller.requestProjection();
      if (!granted) return;
    }
    if (controller.countdownEnabled) {
      final proceed = await _showCountdown();
      if (!proceed) return;
    }
    await controller.startRecording(config);
  }

  Future<bool> _showCountdown() async {
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const _CountdownDialog(),
    );
    return proceed == true;
  }

  Widget _buildSavedCard(RecorderStateSaved state) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.ok),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Ionicons.checkmarkCircleOutline, color: AppColors.ok, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'SAVED',
                style: AppText.mono(size: 13, weight: FontWeight.w800, color: AppColors.ok, spacing: 2),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${state.width}x${state.height} @ ${state.fps}fps - ${_formatDuration(state.durationMs)} - ${_formatBytes(state.sizeBytes)}',
            style: AppText.mono(size: 12, color: AppColors.textMuted),
          ),
          if (state.segmentCount > 1)
            Text(
              'assembled from ${state.segmentCount} segments',
              style: AppText.mono(size: 10, color: AppColors.textFaint),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(RecorderStateError state) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Ionicons.alertCircleOutline, color: AppColors.accent, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text(
                state.code,
                style: AppText.mono(size: 13, weight: FontWeight.w800, color: AppColors.accent, spacing: 1),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            state.message,
            style: AppText.mono(size: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildInterruptedCard(RecorderStateInterrupted state) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.warn),
      ),
      child: Row(
        children: [
          const Icon(Ionicons.warningOutline, color: AppColors.warn, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Session interrupted: ${state.reason}',
              style: AppText.mono(size: 12, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentRecordings(BuildContext context, RecorderController controller) {
    final recent = controller.recordings.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          label: 'RECENT RECORDINGS',
          trailing: TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/library'),
            child: Text(
              'VIEW ALL',
              style: AppText.mono(size: 11, color: AppColors.accent, weight: FontWeight.w700),
            ),
          ),
        ),
        if (recent.isEmpty)
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.line),
            ),
            child: Text(
              'No recordings yet. Saved files appear here after the first session.',
              style: AppText.mono(size: 12, color: AppColors.textMuted),
            ),
          )
        else
          for (final entry in recent) _buildRecordingTile(context, entry),
      ],
    );
  }

  Widget _buildRecordingTile(BuildContext context, RecordingEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Semantics(
        button: true,
        label: 'Open recording ${entry.title}',
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: () => Navigator.of(context).pushNamed('/player', arguments: entry),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(
              children: [
                RecordingThumbnail(uri: entry.uri, controller: controller),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(size: 13, weight: FontWeight.w600),
                      ),
                      Text(
                        '${entry.width}x${entry.height} - ${_formatDuration(entry.durationMs)} - ${_formatBytes(entry.sizeBytes)} - ${entry.codecTag}/${entry.audioTag}',
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(size: 11, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(int ms) {
    final total = ms ~/ 1000;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '--';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}

class _CountdownDialog extends StatefulWidget {
  const _CountdownDialog();

  @override
  State<_CountdownDialog> createState() => _CountdownDialogState();
}

class _CountdownDialogState extends State<_CountdownDialog> {
  int _remaining = 3;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remaining <= 1) {
        timer.cancel();
        Navigator.of(context).pop(true);
      } else {
        setState(() => _remaining -= 1);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'SESSION STARTS IN',
            style: AppText.mono(size: 11, color: AppColors.textMuted, spacing: 2),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '$_remaining',
            style: AppText.mono(size: 64, weight: FontWeight.w800, color: AppColors.accent),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'recording begins when the counter reaches zero',
            textAlign: TextAlign.center,
            style: AppText.mono(size: 10, color: AppColors.textFaint),
          ),
          const SizedBox(height: AppSpacing.md),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'CANCEL',
              style: AppText.mono(size: 12, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

final class ResolutionOption {
  const ResolutionOption(this.width, this.height);

  final int width;
  final int height;
}

final class CodecOption {
  const CodecOption(this.tag, this.label);

  final String tag;
  final String label;
}
