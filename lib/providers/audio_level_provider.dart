import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

/// Watches AudioLevelUpdate.rustSignalStream and exposes the current audio
/// level as a double (0.0 to 1.0). Defaults to 0.0 until the first signal.
final audioLevelProvider = StreamProvider<double>((ref) {
  return AudioLevelUpdate.rustSignalStream.map(
    (signalPack) => signalPack.message.level,
  );
});
