import 'package:flutter/material.dart';
import 'package:ionicons/ionicons.dart';
import 'package:video_player/video_player.dart';

import '../main.dart';
import '../services/recorder_service.dart';
import '../theme.dart';
import '../widgets.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.entry});

  final RecordingEntry entry;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final VideoPlayerController _controller;
  bool _initializing = true;
  bool _capturing = false;
  String? _error;
  String? _captureMessage;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.contentUri(Uri.parse(widget.entry.uri));
    _controller.initialize().then((_) {
      if (_disposed) return;
      setState(() => _initializing = false);
      _controller.addListener(_onControllerUpdate);
    }).catchError((Object failure) {
      if (_disposed) return;
      setState(() {
        _initializing = false;
        _error = failure.toString();
      });
    });
  }

  void _onControllerUpdate() {
    if (_disposed) return;
    if (_controller.value.hasError && _error == null) {
      setState(() => _error = _controller.value.errorDescription ?? 'playback failed');
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.title,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono(size: 13, weight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _buildPlayerSection(),
            const SizedBox(height: AppSpacing.md),
            _buildDetailsSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerSection() {
    if (_initializing) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.line),
        ),
        child: Center(
          child: Text(
            'OPENING STREAM',
            style: AppText.mono(size: 12, color: AppColors.textMuted, spacing: 2),
          ),
        ),
      );
    }
    if (_error != null) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.accent),
        ),
        child: EmptyState(
          icon: Ionicons.alertCircleOutline,
          title: 'Playback failed',
          subtitle: _error ?? 'This file cannot be decoded on this device.',
        ),
      );
    }
    final position = _controller.value.position;
    final duration = _controller.value.duration;
    final positionMs = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: _controller.value.aspectRatio <= 0
                ? 16 / 9
                : _controller.value.aspectRatio,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadii.md),
              ),
              child: VideoPlayer(_controller),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      _formatClock(position),
                      style: AppText.mono(size: 11, color: AppColors.textMuted),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: const SliderThemeData(
                          trackHeight: 3,
                          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                        ),
                        child: Slider(
                          value: positionMs,
                          onChanged: (value) {
                            if (duration.inMilliseconds <= 0) return;
                            final target = (value * duration.inMilliseconds).round();
                            _controller.seekTo(Duration(milliseconds: target));
                          },
                        ),
                      ),
                    ),
                    Text(
                      _formatClock(duration),
                      style: AppText.mono(size: 11, color: AppColors.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                PrimaryAction(
                  height: 48,
                  label: _controller.value.isPlaying ? 'PAUSE' : 'PLAY',
                  icon: _controller.value.isPlaying
                      ? Ionicons.pauseOutline
                      : Ionicons.playOutline,
                  tone: ActionTone.neutral,
                  onTap: () {
                    if (_controller.value.isPlaying) {
                      _controller.pause();
                    } else {
                      _controller.play();
                    }
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                PrimaryAction(
                  height: 48,
                  label: _capturing ? 'CAPTURING FRAME' : 'CAPTURE FRAME',
                  icon: Ionicons.cameraOutline,
                  tone: ActionTone.accent,
                  onTap: _capturing ? null : _onCaptureFrame,
                ),
                if (_captureMessage != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _captureMessage!,
                    textAlign: TextAlign.center,
                    style: AppText.mono(size: 10, color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onCaptureFrame() async {
    final controller = RecorderScope.of(context);
    setState(() {
      _capturing = true;
      _captureMessage = null;
    });
    final positionMs = _controller.value.position.inMilliseconds;
    final outcome = await controller.captureFrame(widget.entry.uri, positionMs);
    if (_disposed) return;
    setState(() {
      _capturing = false;
      _captureMessage = outcome.saved
          ? 'Frame saved to Pictures/BexxCord at ${_formatClock(Duration(milliseconds: positionMs))}'
          : 'Frame could not be extracted at the current position';
    });
  }

  Widget _buildDetailsSection() {
    final entry = widget.entry;
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
          const SectionHeader(label: 'SESSION SUMMARY'),
          _buildDetailRow('RESOLUTION', '${entry.width}x${entry.height}'),
          _buildDetailRow('DURATION', _formatClock(Duration(milliseconds: entry.durationMs))),
          _buildDetailRow('SIZE', _formatBytes(entry.sizeBytes)),
          _buildDetailRow('VIDEO CODEC', entry.codecTag.toUpperCase()),
          _buildDetailRow(
            'AUDIO SOURCE',
            switch (entry.audioTag) {
              'sys' => 'SYSTEM PLAYBACK',
              'mic' => 'MICROPHONE',
              _ => 'NONE',
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: AppText.mono(size: 10, color: AppColors.textMuted, spacing: 1),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppText.mono(size: 12),
            ),
          ),
        ],
      ),
    );
  }

  String _formatClock(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '--';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}
