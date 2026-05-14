import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

import 'local_models_snapshot_provider.dart';

class ModelOperationState {
  const ModelOperationState({required this.state, required this.modelId});

  final ModelState state;
  final String modelId;
}

final selectedModelStateProvider = Provider<ModelOperationState?>((ref) {
  final snapshot = ref.watch(localModelsSnapshotProvider).value;
  if (snapshot == null) return null;
  final state = snapshot.stateFor(snapshot.selectedModelId);
  if (state == null) return null;
  return ModelOperationState(state: state, modelId: snapshot.selectedModelId);
});

final globalModelOperationProvider = Provider<ModelOperationState?>((ref) {
  final snapshot = ref.watch(localModelsSnapshotProvider).value;
  if (snapshot == null || snapshot.modelStates.isEmpty) return null;

  int priorityFor(ModelState state) => switch (state) {
    ModelStateDownloading() => 0,
    ModelStateLoading() => 1,
    ModelStateWarming() => 2,
    ModelStateError() => 3,
    ModelStateReady() => 99,
    ModelStateNotDownloaded() => 100,
    _ => 1000,
  };

  ModelOperationState? best;
  var bestPriority = 1000;

  for (final entry in snapshot.modelStates.entries) {
    final priority = priorityFor(entry.value);
    if (priority > 3) continue;
    if (best == null || priority < bestPriority) {
      best = ModelOperationState(state: entry.value, modelId: entry.key);
      bestPriority = priority;
      continue;
    }
    if (priority == bestPriority &&
        entry.key == snapshot.selectedModelId &&
        best.modelId != snapshot.selectedModelId) {
      best = ModelOperationState(state: entry.value, modelId: entry.key);
    }
  }

  return best;
});
