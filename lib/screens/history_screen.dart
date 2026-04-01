import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/providers/history_provider.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';
import 'package:wrenflow/theme/wrenflow_theme.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    LoadHistory().sendSignalToRust();
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(historyProvider);

    return Scaffold(
      backgroundColor: WrenflowStyle.bg,
      body: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('History', style: WrenflowStyle.title(16)),
                if (entries.isNotEmpty)
                  GestureDetector(
                    onTap: () => _confirmClearAll(context),
                    child: Text(
                      'Clear',
                      style: WrenflowStyle.body(12).copyWith(
                        color: WrenflowStyle.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Content
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      'No transcriptions yet',
                      style: WrenflowStyle.body(13).copyWith(
                        color: WrenflowStyle.textTertiary,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return _HistoryRow(
                        entry: entry,
                        onDelete: () => _deleteEntry(entry.id),
                        onTap: () => _showDetail(context, entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _deleteEntry(String id) {
    ref.read(historyProvider.notifier).removeEntry(id);
    DeleteHistoryEntry(id: id).sendSignalToRust();
  }

  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear History'),
        content: const Text('Delete all transcription history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(historyProvider.notifier).clearAll();
              ClearHistory().sendSignalToRust();
            },
            child: Text('Clear',
                style: TextStyle(color: WrenflowStyle.red)),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context, HistoryEntryData entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transcription'),
        content: SingleChildScrollView(
          child: SelectableText(entry.transcript),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.onDelete,
    required this.onTap,
  });

  final HistoryEntryData entry;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      (entry.timestamp * 1000).toInt(),
    );
    final timeStr =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: WrenflowStyle.surface,
          borderRadius: BorderRadius.circular(WrenflowStyle.radiusMedium),
          border: Border.all(color: WrenflowStyle.border, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$dateStr $timeStr',
                    style: WrenflowStyle.caption(11),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.transcript,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: WrenflowStyle.body(13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onDelete,
              child: Icon(
                CupertinoIcons.xmark,
                size: 12,
                color: WrenflowStyle.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
