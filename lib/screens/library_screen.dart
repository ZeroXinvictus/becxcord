import 'package:flutter/material.dart';
import 'package:ionicons/ionicons.dart';

import '../main.dart';
import '../services/recorder_service.dart';
import '../theme.dart';
import '../widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _refreshed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_refreshed) return;
    _refreshed = true;
    RecorderScope.of(context).refreshRecordings();
  }

  @override
  Widget build(BuildContext context) {
    final controller = RecorderScope.of(context);
    final recordings = controller.recordings;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'LIBRARY',
          style: AppText.mono(size: 14, weight: FontWeight.w800, letterSpacing: 2),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh library',
            icon: const Icon(Ionicons.refresh_outline, color: AppColors.textMuted),
            onPressed: controller.refreshRecordings,
          ),
        ],
      ),
      body: SafeArea(
        child: recordings.isEmpty
            ? const EmptyState(
                icon: Ionicons.folder_open_outline,
                title: 'No recordings',
                subtitle:
                    'Finished sessions are saved to Movies/BexxCord and indexed here automatically.',
              )
            : RefreshIndicator(
                color: AppColors.accent,
                onRefresh: controller.refreshRecordings,
                child: ListView.builder(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: recordings.length,
                  itemBuilder: (context, index) =>
                      _RecordingTile(entry: recordings[index]),
                ),
              ),
      ),
    );
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile({required this.entry});

  final RecordingEntry entry;

  @override
  Widget build(BuildContext context) {
    final controller = RecorderScope.of(context);
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
                        '${entry.width}x${entry.height} - ${_formatDuration(entry.durationMs)} - ${_formatBytes(entry.sizeBytes)}',
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(size: 11, color: AppColors.textMuted),
                      ),
                      Text(
                        '${entry.codecTag}/${entry.audioTag} - ${_formatDate(entry.createdAtMs)}',
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(size: 10, color: AppColors.textFaint),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Rename recording',
                  icon: const Icon(Ionicons.create_outline, color: AppColors.textMuted, size: 18),
                  onPressed: () => _showRenameDialog(context, controller),
                ),
                IconButton(
                  tooltip: 'Delete recording',
                  icon: const Icon(Ionicons.trash_outline, color: AppColors.accent, size: 18),
                  onPressed: () => _showDeleteDialog(context, controller),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    RecorderController controller,
  ) async {
    final textController = TextEditingController(text: entry.title);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('RENAME', style: AppText.mono(size: 13, weight: FontWeight.w800, letterSpacing: 2)),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLength: 64,
          style: AppText.mono(size: 13),
          decoration: InputDecoration(
            border: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.line)),
            focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            counterStyle: AppText.mono(size: 10, color: AppColors.textFaint),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('CANCEL', style: AppText.mono(size: 12, color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(textController.text),
            child: Text('SAVE', style: AppText.mono(size: 12, color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      final renamed = await controller.renameRecording(entry, result.trim());
      if (!renamed && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rename failed')),
        );
      }
    }
  }

  Future<void> _showDeleteDialog(
    BuildContext context,
    RecorderController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('DELETE', style: AppText.mono(size: 13, weight: FontWeight.w800, letterSpacing: 2)),
        content: Text(
          'Permanently delete ${entry.title}? This cannot be undone.',
          style: AppText.mono(size: 12, color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('CANCEL', style: AppText.mono(size: 12, color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('DELETE', style: AppText.mono(size: 12, color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final deleted = await controller.deleteRecording(entry);
      if (!deleted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Delete failed')),
        );
      }
    }
  }

  String _formatDuration(int ms) {
    final total = ms ~/ 1000;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '--';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _formatDate(int epochMs) {
    if (epochMs <= 0) return 'unknown date';
    final date = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
