import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

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

final localModelsStatusProvider = StreamProvider<LocalModelsStatus>((
  ref,
) async* {
  const RequestLocalModelsStatus().sendSignalToRust();

  yield* LocalModelsStatusChanged.rustSignalStream.map((signalPack) {
    final message = signalPack.message;
    return LocalModelsStatus(
      selectedModelId: message.selectedModelId,
      activeModelId: message.activeModelId,
      installedModelIds: message.installedModelIds.toSet(),
    );
  });
});
