import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_models_snapshot_provider.dart';

class LocalModelsStatus {
  const LocalModelsStatus({
    required this.selectedModelId,
    required this.activeModelId,
    required this.installedModelIds,
  });

  final String selectedModelId;
  final String? activeModelId;
  final Set<String> installedModelIds;

  bool isInstalled(String modelId) => installedModelIds.contains(modelId);
  bool isActive(String modelId) => activeModelId == modelId;
  bool isSelected(String modelId) => selectedModelId == modelId;
}

final localModelsStatusProvider = Provider<LocalModelsStatus?>((ref) {
  final snapshot = ref.watch(localModelsSnapshotProvider).value;
  if (snapshot == null) return null;
  return LocalModelsStatus(
    selectedModelId: snapshot.selectedModelId,
    activeModelId: snapshot.activeModelId,
    installedModelIds: snapshot.installedModelIds,
  );
});
