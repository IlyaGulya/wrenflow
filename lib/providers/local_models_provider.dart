import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_models_snapshot_provider.dart';

export 'local_models_snapshot_provider.dart'
    show LocalModelDescriptor, LocalModelsSnapshot, localModelsSnapshotProvider;

final localModelsProvider = Provider<List<LocalModelDescriptor>>((ref) {
  return ref.watch(
        localModelsSnapshotProvider.select(
          (snapshot) => snapshot.value?.models,
        ),
      ) ??
      const <LocalModelDescriptor>[];
});

final selectedLocalModelProvider = Provider<LocalModelDescriptor?>((ref) {
  final snapshot = ref.watch(localModelsSnapshotProvider).value;
  if (snapshot == null) return null;
  return snapshot.findModel(snapshot.selectedModelId);
});
