import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

/// Watches ModelStateChanged.rustSignalStream and exposes the current
/// [ModelState]. Defaults to loading state until the first signal arrives.
final modelStateProvider = StreamProvider<ModelState>((ref) {
  return ModelStateChanged.rustSignalStream.map(
    (signalPack) => signalPack.message.state,
  );
});
