import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ionicons/ionicons.dart';
import 'services/recorder_service.dart';
import 'theme.dart';

class TerminalPanel extends StatelessWidget {
  const TerminalPanel({
    super.key,
    required this.lines,
    this.busy = false,
  });

  final List<StatusLineData> lines;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: const BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(AppRadii.md),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'bexxcord://session',
                  style: AppText.mono(
                    size: 11,
                    color: AppColors.textMuted,
                    spacing: 1,
                  ),
                ),
                const Spacer(),
                if (busy)
                  const BlinkingCursor()
                else
                  Text(
                    'IDLE',
                    style: AppText.mono(
                      size: 11,
                      color: AppColors.textFaint,
                      spacing: 1,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                for (final line in lines) StatusLine(data: line),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StatusLineData {
  const StatusLineData(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;
}

class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.data});

  final StatusLineData data;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              data.label,
              style: AppText.mono(size: 12, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              data.value,
              style: AppText.mono(size: 13, color: data.color ?? AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class BlinkingCursor extends StatefulWidget {
  const BlinkingCursor({super.key});

  @override
  State<BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 14,
        color: AppColors.accent,
      ),
    );
  }
}

enum CapabilityState { ok, warn, off }

class CapabilityChip extends StatelessWidget {
  const CapabilityChip({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.state,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final CapabilityState state;
  final VoidCallback? onTap;

  Color get _foreground => switch (state) {
        CapabilityState.ok => AppColors.ok,
        CapabilityState.warn => AppColors.warn,
        CapabilityState.off => AppColors.textFaint,
      };

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: _foreground.withAlpha(102)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _foreground),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppText.mono(size: 9, color: AppColors.textMuted, spacing: 1),
              ),
              Text(
                value,
                style: AppText.mono(size: 11, color: _foreground, weight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
      button: true,
      label: '$label $value',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        onTap: onTap,
        child: chip,
      ),
    );
  }
}

enum ActionTone { accent, neutral, danger }

class PrimaryAction extends StatefulWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.tone = ActionTone.accent,
    this.enabled = true,
    this.height = 64,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final ActionTone tone;
  final bool enabled;
  final double height;

  @override
  State<PrimaryAction> createState() => _PrimaryActionState();
}

class _PrimaryActionState extends State<PrimaryAction> {
  bool _pressed = false;

  Color get _background => switch (widget.tone) {
        ActionTone.accent => widget.enabled ? AppColors.accent : AppColors.surfaceRaised,
        ActionTone.neutral => AppColors.surfaceRaised,
        ActionTone.danger => AppColors.accentDeep,
      };

  List<BoxShadow> get _shadow => switch (widget.tone) {
        ActionTone.accent => widget.enabled ? AppShadows.accent3D() : AppShadows.soft3D(),
        _ => AppShadows.soft3D(),
      };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.enabled ? widget.onTap : null,
      )
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          height: widget.height,
          transform: Matrix4.translationValues(0, _pressed ? 3 : 0, 0),
          decoration: BoxDecoration(
            color: _background,
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(
              color: widget.tone == ActionTone.neutral ? AppColors.line : Colors.transparent,
            ),
            boxShadow: _shadow,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                color: widget.enabled ? Colors.white : AppColors.textMuted,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                widget.label,
                style: AppText.mono(
                  size: 15,
                  weight: FontWeight.w700,
                  spacing: 2,
                  color: widget.enabled ? Colors.white : AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Text(
            label,
            style: AppText.mono(
              size: 11,
              color: AppColors.textMuted,
              weight: FontWeight.w700,
              spacing: 2,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, this.onDismiss});

  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.accent),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Ionicons.alertCircleOutline, color: AppColors.accent, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppText.mono(size: 12, color: AppColors.textPrimary),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              icon: const Icon(Ionicons.closeOutline, color: AppColors.textMuted, size: 16),
              onPressed: onDismiss,
              tooltip: 'Dismiss error',
            ),
        ],
      ),
    );
  }
}

class RecordingThumbnail extends StatefulWidget {
  const RecordingThumbnail({
    super.key,
    required this.uri,
    required this.controller,
    this.width = 72,
    this.height = 44,
  });

  final String uri;
  final RecorderController controller;
  final double width;
  final double height;

  @override
  State<RecordingThumbnail> createState() => _RecordingThumbnailState();
}

class _RecordingThumbnailState extends State<RecordingThumbnail> {
  Uint8List? _bytes;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.controller.thumbnailFor(widget.uri).then((bytes) {
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loaded = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.line),
      ),
      child: _bytes == null
          ? Center(
              child: Icon(
                _loaded ? Ionicons.filmOutline : Ionicons.hourglassOutline,
                color: _loaded ? AppColors.textFaint : AppColors.textMuted,
                size: 18,
              ),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: Image.memory(
                _bytes!,
                fit: BoxFit.cover,
                width: widget.width,
                height: widget.height,
                gaplessPlayback: true,
              ),
            ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textFaint),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.mono(size: 16, weight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppText.mono(size: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
