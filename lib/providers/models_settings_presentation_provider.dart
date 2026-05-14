import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_model_status_provider.dart';
import 'local_models_provider.dart';
import 'runtime_capabilities_provider.dart';

class ModelsSettingsPresentation {
  const ModelsSettingsPresentation({
    required this.preferredModelLabel,
    required this.activeModelLabel,
    required this.installedCountLabel,
    required this.runtimeHint,
  });

  final String preferredModelLabel;
  final String activeModelLabel;
  final String installedCountLabel;
  final String? runtimeHint;
}

final modelsSettingsPresentationProvider =
    Provider<ModelsSettingsPresentation>((ref) {
      final modelStatus = ref.watch(localModelsStatusProvider);
      final models = ref.watch(localModelsProvider);
      final selectedModel = ref.watch(selectedLocalModelProvider);
      final runtimeCapabilities = ref.watch(runtimeCapabilitiesProvider).value;

      final activeModelId = modelStatus?.activeModelId;
      final activeModel = activeModelId == null
          ? null
          : models.where((model) => model.id == activeModelId).isEmpty
          ? null
          : models.firstWhere((model) => model.id == activeModelId);

      return ModelsSettingsPresentation(
        preferredModelLabel: selectedModel?.displayName ?? 'Loading...',
        activeModelLabel: activeModel?.displayName ?? 'None',
        installedCountLabel: '${modelStatus?.installedModelIds.length ?? 0}',
        runtimeHint: runtimeCapabilities == null
            ? 'Loading runtime support...'
            : runtimeCapabilities.localTranscription &&
                  runtimeCapabilities.modelDownload &&
                  runtimeCapabilities.modelActivation
            ? null
            : 'Local model runtime is not fully available on this platform yet.',
      );
    });
