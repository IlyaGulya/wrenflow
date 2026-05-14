import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

class ModelOperationState {
  const ModelOperationState({required this.state, required this.modelId});

  final ModelState state;
  final String? modelId;
}

/// Projection of the Rust model operation stream.
final modelStateProvider = StreamProvider<ModelOperationState>((ref) {
  return ModelStateChanged.rustSignalStream.map((signalPack) {
    final message = signalPack.message;
    return ModelOperationState(state: message.state, modelId: message.modelId);
  });
});
