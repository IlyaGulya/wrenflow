import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_model_status_provider.dart';
import 'local_models_provider.dart';

class ModelsSettingsPresentation {
  const ModelsSettingsPresentation({
    required this.preferredModelLabel,
    required this.activeModelLabel,
    required this.installedCountLabel,
  });

  final String preferredModelLabel;
  final String activeModelLabel;
  final String installedCountLabel;
}

final modelsSettingsPresentationProvider =
    Provider<ModelsSettingsPresentation>((ref) {
      final modelStatus = ref.watch(localModelsStatusProvider);
      final models = ref.watch(localModelsProvider);
      final selectedModel = ref.watch(selectedLocalModelProvider);

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
      );
    });
