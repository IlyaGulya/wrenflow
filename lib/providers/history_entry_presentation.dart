import 'dart:convert';

import '../src/bindings/signals/signals.dart';

class HistoryEntryPresentation {
  const HistoryEntryPresentation({
    required this.metrics,
    required this.durationBadge,
    required this.modelBadge,
  });

  final Map<String, dynamic> metrics;
  final String? durationBadge;
  final String? modelBadge;

  static HistoryEntryPresentation fromEntry(HistoryEntryData entry) {
    final metrics = _parseMetrics(entry.metricsJson);
    return HistoryEntryPresentation(
      metrics: metrics,
      durationBadge: _formatDuration(metrics),
      modelBadge: _formatModel(metrics),
    );
  }

  static Map<String, dynamic> _parseMetrics(String json) {
    if (json.isEmpty || json == '{}') return {};
    try {
      return (const JsonDecoder().convert(json)) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static String? _formatDuration(Map<String, dynamic> metrics) {
    final durationMs = metrics['transcription.durationMs'];
    if (durationMs is num) {
      return '${durationMs.round()}ms';
    }
    return null;
  }

  static String? _formatModel(Map<String, dynamic> metrics) {
    final modelName = metrics['transcription.modelName'];
    if (modelName is String && modelName.isNotEmpty) {
      return modelName;
    }
    final modelId = metrics['transcription.modelId'];
    if (modelId is String && modelId.isNotEmpty) {
      return modelId;
    }
    return null;
  }
}

String formatHistoryMetricValue(dynamic value) {
  if (value is num) return value.toString();
  if (value is bool) return value ? 'true' : 'false';
  if (value is String) return value;
  if (value == null) return 'null';
  return value.toString();
}
