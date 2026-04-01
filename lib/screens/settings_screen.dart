import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rinf/rinf.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wrenflow/providers/history_provider.dart';
import 'package:wrenflow/providers/settings_provider.dart';
import 'package:wrenflow/providers/update_provider.dart';
import 'package:wrenflow/services/update_service.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';
import 'package:wrenflow/theme/wrenflow_theme.dart';
import 'package:wrenflow/widgets/green_toggle.dart';
import 'package:wrenflow/widgets/hotkey_capture.dart';
import 'package:wrenflow/widgets/settings_card.dart';


/// Sidebar tab definition.
enum SettingsTab {
  general(CupertinoIcons.gear, 'General'),
  history(CupertinoIcons.clock, 'History'),
  about(CupertinoIcons.info, 'About');

  const SettingsTab(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Settings screen — 720×520, sidebar + content layout.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.initialTab = SettingsTab.general});

  final SettingsTab initialTab;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late SettingsTab _selectedTab;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      setState(() => _selectedTab = widget.initialTab);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WrenflowStyle.bg,
      body: Row(
        children: [
          // Sidebar
          _buildSidebar(),

          // Divider
          Container(width: 0.5, color: WrenflowStyle.border),

          // Content
          Expanded(
            child: switch (_selectedTab) {
              SettingsTab.general => const _GeneralContent(),
              SettingsTab.history => const _HistoryContent(),
              SettingsTab.about => const _AboutContent(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Traffic light inset
          const SizedBox(height: 28),

          // App icon
          Opacity(
            opacity: 0.6,
            child: Image.asset(
              'assets/icon.png',
              width: 64,
              height: 64,
              errorBuilder: (_, __, ___) => Icon(
                CupertinoIcons.waveform,
                size: 40,
                color: WrenflowStyle.textOp60,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // App name
          Text('Wrenflow', style: WrenflowStyle.body(12)),
          const SizedBox(height: 2),

          // Version
          Text(
            'v1.0.0',
            style: WrenflowStyle.mono(10).copyWith(
              color: WrenflowStyle.textTertiary,
            ),
          ),
          const SizedBox(height: 12),

          // Divider
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(height: 0.5, color: WrenflowStyle.border),
          ),
          const SizedBox(height: 8),

          // Tab buttons
          for (final tab in SettingsTab.values)
            _buildTabButton(tab),

          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildTabButton(SettingsTab tab) {
    final isSelected = _selectedTab == tab;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = tab),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? WrenflowStyle.textOp07 : Colors.transparent,
          borderRadius: BorderRadius.circular(WrenflowStyle.radiusSmall),
        ),
        child: Row(
          children: [
            Icon(
              tab.icon,
              size: 11,
              color: isSelected ? WrenflowStyle.text : WrenflowStyle.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              tab.label,
              style: WrenflowStyle.body(13).copyWith(
                color: isSelected
                    ? WrenflowStyle.text
                    : WrenflowStyle.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── General tab content ──────────────────────────────────────

class _GeneralContent extends ConsumerStatefulWidget {
  const _GeneralContent();

  @override
  ConsumerState<_GeneralContent> createState() => _GeneralContentState();
}

class _GeneralContentState extends ConsumerState<_GeneralContent> {
  late TextEditingController _vocabularyController;
  Timer? _vocabularyDebounce;
  List<AudioDeviceInfo> _audioDevices = [];
  String _defaultDeviceName = '';
  StreamSubscription<RustSignalPack<AudioDevicesListed>>? _deviceSubscription;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _vocabularyController =
        TextEditingController(text: settings.customVocabulary);

    _deviceSubscription =
        AudioDevicesListed.rustSignalStream.listen((signal) {
      if (mounted) {
        setState(() {
          _audioDevices = signal.message.devices;
          _defaultDeviceName = signal.message.defaultDeviceName;
        });
      }
    });

    const ListAudioDevices().sendSignalToRust();
  }

  @override
  void dispose() {
    _vocabularyController.dispose();
    _vocabularyDebounce?.cancel();
    _deviceSubscription?.cancel();
    super.dispose();
  }

  void _onVocabularyChanged(String value) {
    _vocabularyDebounce?.cancel();
    _vocabularyDebounce = Timer(const Duration(milliseconds: 500), () {
      ref.read(settingsProvider.notifier).setCustomVocabulary(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hotkey card
          SettingsCard(
            title: 'Push-to-talk key',
            child: _buildHotkeyOptions(settings),
          ),
          const SizedBox(height: 16),

          // Microphone card
          SettingsCard(
            title: 'Microphone',
            child: _buildMicrophoneDropdown(settings),
          ),
          const SizedBox(height: 16),

          // Sound effects card
          SettingsCard(
            title: 'Sound effects',
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Play sounds', style: WrenflowStyle.body(12)),
                GreenToggle(
                  value: settings.soundEnabled,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setSoundEnabled(v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Min duration card
          SettingsCard(
            title: 'Minimum recording duration',
            child: _buildDurationSlider(settings),
          ),
          const SizedBox(height: 16),

          // Vocabulary card
          SettingsCard(
            title: 'Custom vocabulary',
            child: _buildVocabularyField(),
          ),
        ],
      ),
    );
  }

  Widget _buildHotkeyOptions(AppSettings settings) {
    return HotkeyCapture(
      currentValue: settings.selectedHotkey,
      onKeySelected: (value) =>
          ref.read(settingsProvider.notifier).setSelectedHotkey(value),
    );
  }

  Widget _buildMicrophoneDropdown(AppSettings settings) {
    final defaultLabel = _defaultDeviceName.isNotEmpty
        ? 'System Default ($_defaultDeviceName)'
        : 'System Default';
    final items = <_DropdownItem>[
      _DropdownItem('default', defaultLabel),
      for (final device in _audioDevices)
        _DropdownItem(device.id, device.name),
    ];

    final effectiveId =
        items.any((i) => i.value == settings.selectedMicrophoneId)
            ? settings.selectedMicrophoneId
            : 'default';

    return Column(
      children: items.map((item) {
        final isSelected = effectiveId == item.value;
        return GestureDetector(
          onTap: () => ref
              .read(settingsProvider.notifier)
              .setSelectedMicrophoneId(item.value),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color:
                  isSelected ? WrenflowStyle.textOp05 : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                Icon(
                  isSelected
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  size: 13,
                  color: isSelected
                      ? WrenflowStyle.text
                      : WrenflowStyle.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.label,
                    style: WrenflowStyle.body(12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDurationSlider(AppSettings settings) {
    final durationMs = settings.minimumRecordingDurationMs;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Duration', style: WrenflowStyle.body(12)),
            Text(
              '${durationMs.round()} ms',
              style: WrenflowStyle.mono(10).copyWith(
                color: WrenflowStyle.textTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: WrenflowStyle.trackFill,
            inactiveTrackColor: WrenflowStyle.trackBg,
            thumbColor: Colors.white,
            overlayColor: WrenflowStyle.textOp10,
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: durationMs,
            min: 100,
            max: 1000,
            divisions: 18,
            onChanged: (value) => ref
                .read(settingsProvider.notifier)
                .setMinimumRecordingDurationMs(value),
          ),
        ),
      ],
    );
  }

  Widget _buildVocabularyField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Words or phrases to improve recognition, one per line.',
          style: WrenflowStyle.caption(11),
        ),
        const SizedBox(height: 8),
        Container(
          height: 64,
          decoration: BoxDecoration(
            color: WrenflowStyle.bg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: WrenflowStyle.border, width: 1),
          ),
          child: TextField(
            controller: _vocabularyController,
            maxLines: null,
            expands: true,
            onChanged: _onVocabularyChanged,
            style: WrenflowStyle.mono(11),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(8),
              hintText: 'e.g.\nWrenflow\nRiverpod',
              hintStyle: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: Color.fromRGBO(153, 153, 153, 1.0),
              ),
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }
}

class _DropdownItem {
  const _DropdownItem(this.value, this.label);
  final String value;
  final String label;
}

// ── History tab content ───────────────────────────────────────

class _HistoryContent extends ConsumerStatefulWidget {
  const _HistoryContent();

  @override
  ConsumerState<_HistoryContent> createState() => _HistoryContentState();
}

class _HistoryContentState extends ConsumerState<_HistoryContent> {
  @override
  void initState() {
    super.initState();
    LoadHistory().sendSignalToRust();
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(historyProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with clear button
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('History', style: WrenflowStyle.title(16)),
              if (entries.isNotEmpty)
                GestureDetector(
                  onTap: () => _confirmClearAll(context),
                  child: Text(
                    'Clear all',
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
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return _HistoryRow(
                      entry: entry,
                      onDelete: () => _deleteEntry(entry.id),
                    );
                  },
                ),
        ),
      ],
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

}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    required this.entry,
    required this.onDelete,
  });

  final HistoryEntryData entry;
  final VoidCallback onDelete;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final date = DateTime.fromMillisecondsSinceEpoch(
      (entry.timestamp * 1000).toInt(),
    );
    final timeStr =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    final metrics = _parseMetrics(entry.metricsJson);
    final durationBadge = _formatDuration(metrics);

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: WrenflowStyle.surface,
          borderRadius: BorderRadius.circular(WrenflowStyle.radiusMedium),
          border: Border.all(color: WrenflowStyle.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('$dateStr $timeStr',
                              style: WrenflowStyle.caption(11)),
                          if (durationBadge != null) ...[
                            const SizedBox(width: 6),
                            _MetricBadge(durationBadge),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.transcript,
                        maxLines: _expanded ? null : 2,
                        overflow:
                            _expanded ? null : TextOverflow.ellipsis,
                        style: WrenflowStyle.body(13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _expanded
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  size: 10,
                  color: WrenflowStyle.textTertiary,
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: widget.onDelete,
                  child: Icon(
                    CupertinoIcons.xmark,
                    size: 12,
                    color: WrenflowStyle.textTertiary,
                  ),
                ),
              ],
            ),

            // Expanded metrics
            if (_expanded && metrics.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: WrenflowStyle.bg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final key in metrics.keys.toList()..sort())
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 160,
                              child: Text(
                                key,
                                style: WrenflowStyle.mono(10).copyWith(
                                  color: WrenflowStyle.textTertiary,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _formatMetricValue(metrics[key]),
                                style: WrenflowStyle.mono(10).copyWith(
                                  color: WrenflowStyle.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _parseMetrics(String json) {
    if (json.isEmpty || json == '{}') return {};
    try {
      final decoded = (const JsonDecoder().convert(json)) as Map<String, dynamic>;
      return decoded;
    } catch (_) {
      return {};
    }
  }

  String? _formatDuration(Map<String, dynamic> metrics) {
    final rec = metrics['recording.durationMs'];
    if (rec is num && rec > 0) {
      if (rec >= 1000) {
        return '${(rec / 1000).toStringAsFixed(1)}s';
      }
      return '${rec.round()}ms';
    }
    return null;
  }

  String _formatMetricValue(dynamic value) {
    if (value is double) {
      if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}s';
      return '${value.toStringAsFixed(1)}ms';
    }
    if (value is int) return value.toString();
    if (value is bool) return value ? 'true' : 'false';
    return value?.toString() ?? '';
  }
}

class _MetricBadge extends StatelessWidget {
  const _MetricBadge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: WrenflowStyle.textOp07,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: WrenflowStyle.mono(10)),
    );
  }
}

// ── About tab content ────────────────────────────────────────

class _AboutContent extends ConsumerWidget {
  const _AboutContent();

  static const _githubUrl = 'https://github.com/IlyaGulya/wrenflow';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateAsync = ref.watch(updateProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Opacity(
            opacity: 0.6,
            child: Image.asset(
              'assets/icon.png',
              width: 64,
              height: 64,
              errorBuilder: (_, __, ___) => Icon(
                CupertinoIcons.waveform,
                size: 40,
                color: WrenflowStyle.textOp60,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('Wrenflow', style: WrenflowStyle.title(16)),
          const SizedBox(height: 4),
          Text(
            'v${GitHubUpdateSource.currentVersion}',
            style: WrenflowStyle.mono(10).copyWith(
              color: WrenflowStyle.textTertiary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Hold a key to record, release to transcribe.',
            style: WrenflowStyle.caption(12),
          ),
          const SizedBox(height: 20),

          // Update section
          SettingsCard(
            title: 'Updates',
            child: updateAsync.when(
              loading: () => Row(
                children: [
                  SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: WrenflowStyle.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('Checking for updates...',
                      style: WrenflowStyle.body(12)),
                ],
              ),
              error: (_, __) => _updateRow(
                'Could not check for updates',
                actionLabel: 'Retry',
                onAction: () => ref.read(updateProvider.notifier).checkNow(),
              ),
              data: (info) => info.isAvailable
                  ? _updateAvailable(context, ref, info)
                  : _updateRow(
                      'You\'re up to date',
                      actionLabel: 'Check now',
                      onAction: () =>
                          ref.read(updateProvider.notifier).checkNow(),
                    ),
            ),
          ),
          const SizedBox(height: 16),

          GestureDetector(
            onTap: () async {
              final uri = Uri.parse(_githubUrl);
              if (await canLaunchUrl(uri)) await launchUrl(uri);
            },
            child: Text(
              'View on GitHub',
              style: WrenflowStyle.body(12).copyWith(
                color: WrenflowStyle.textOp50,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _updateAvailable(
      BuildContext context, WidgetRef ref, UpdateInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'v${info.latestVersion} is available',
          style: WrenflowStyle.body(12),
        ),
        if (info.isRecent)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Released recently — you may want to wait a few days.',
              style: WrenflowStyle.caption(11),
            ),
          ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () async {
            final url = info.downloadUrl.isNotEmpty
                ? info.downloadUrl
                : info.releaseUrl;
            final uri = Uri.parse(url);
            if (await canLaunchUrl(uri)) await launchUrl(uri);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: WrenflowStyle.text,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Download Update',
              style: WrenflowStyle.body(12).copyWith(color: WrenflowStyle.surface),
            ),
          ),
        ),
      ],
    );
  }

  Widget _updateRow(String text,
      {required String actionLabel, required VoidCallback onAction}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(text, style: WrenflowStyle.body(12)),
        GestureDetector(
          onTap: onAction,
          child: Text(
            actionLabel,
            style: WrenflowStyle.body(12).copyWith(
              color: WrenflowStyle.textOp50,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    );
  }
}
