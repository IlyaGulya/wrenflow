import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_provider.dart';

class LocalModelDescriptor {
  const LocalModelDescriptor({
    required this.id,
    required this.displayName,
    required this.subtitle,
    required this.downloadLabel,
    required this.family,
    required this.runtimeLabel,
    required this.isRecommended,
    required this.isAvailable,
    required this.supportsCurrentRuntime,
  });

  final String id;
  final String displayName;
  final String subtitle;
  final String downloadLabel;
  final String family;
  final String runtimeLabel;
  final bool isRecommended;
  final bool isAvailable;
  final bool supportsCurrentRuntime;
}

const _localModels = <LocalModelDescriptor>[
  LocalModelDescriptor(
    id: 'parakeet-tdt-0.6b-v3-onnx',
    displayName: 'Parakeet Realtime',
    subtitle: 'Fastest local dictation for the current ONNX runtime.',
    downloadLabel: '~400 MB',
    family: 'Parakeet',
    runtimeLabel: 'ONNX',
    isRecommended: true,
    isAvailable: true,
    supportsCurrentRuntime: true,
  ),
  LocalModelDescriptor(
    id: 'whisper-large-v3-turbo-onnx',
    displayName: 'Whisper Turbo',
    subtitle: 'Fast high-quality Whisper with the new local ONNX runtime.',
    downloadLabel: '~1.2 GB',
    family: 'Whisper',
    runtimeLabel: 'ONNX',
    isRecommended: false,
    isAvailable: true,
    supportsCurrentRuntime: true,
  ),
  LocalModelDescriptor(
    id: 'whisper-large-v3-onnx',
    displayName: 'Whisper Large',
    subtitle: 'Highest Whisper accuracy target once the ONNX path lands.',
    downloadLabel: 'Whisper runtime pending',
    family: 'Whisper',
    runtimeLabel: 'Planned ONNX',
    isRecommended: false,
    isAvailable: false,
    supportsCurrentRuntime: false,
  ),
];

final localModelsProvider = Provider<List<LocalModelDescriptor>>((ref) {
  return _localModels;
});

final selectedLocalModelProvider = Provider<LocalModelDescriptor>((ref) {
  final selectedId = ref.watch(
    settingsProvider.select((settings) => settings.selectedLocalModelId),
  );
  final models = ref.watch(localModelsProvider);
  return models.firstWhere(
    (model) => model.id == selectedId,
    orElse: () => models.first,
  );
});
