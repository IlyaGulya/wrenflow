import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

import 'rust_snapshot_bridge.dart';

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

class LocalModelsSnapshot {
  const LocalModelsSnapshot({
    required this.models,
    required this.selectedModelId,
    required this.activeModelId,
    required this.installedModelIds,
    required this.modelStates,
  });

  final List<LocalModelDescriptor> models;
  final String selectedModelId;
  final String? activeModelId;
  final Set<String> installedModelIds;
  final Map<String, ModelState> modelStates;

  bool isInstalled(String modelId) => installedModelIds.contains(modelId);
  bool isActive(String modelId) => activeModelId == modelId;
  bool isSelected(String modelId) => selectedModelId == modelId;

  LocalModelDescriptor? findModel(String? modelId) {
    if (modelId == null) return null;
    for (final model in models) {
      if (model.id == modelId) return model;
    }
    return null;
  }

  ModelState? stateFor(String? modelId) {
    if (modelId == null) return null;
    return modelStates[modelId];
  }
}

final localModelsSnapshotProvider = StreamProvider<LocalModelsSnapshot>(
  (ref) => rustSnapshotStream(
    requestSnapshot: () =>
        const RequestLocalModelsSnapshot().sendSignalToRust(),
    signalStream: LocalModelsSnapshotChanged.rustSignalStream,
    map: (message) {
      return LocalModelsSnapshot(
        models: message.models
            .map(
              (model) => LocalModelDescriptor(
                id: model.id,
                displayName: model.displayName,
                subtitle: model.subtitle,
                downloadLabel: model.downloadLabel,
                family: model.family,
                runtimeLabel: model.runtimeLabel,
                isRecommended: model.isRecommended,
                isAvailable: model.isAvailable,
                supportsCurrentRuntime: model.supportsCurrentRuntime,
              ),
            )
            .toList(growable: false),
        selectedModelId: message.selectedModelId,
        activeModelId: message.activeModelId,
        installedModelIds: message.installedModelIds.toSet(),
        modelStates: {
          for (final entry in message.modelStates) entry.modelId: entry.state,
        },
      );
    },
  ),
);
