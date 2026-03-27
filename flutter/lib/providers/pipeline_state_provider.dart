import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

/// Watches PipelineStateChanged.rustSignalStream and exposes the current
/// [PipelineState]. Defaults to [PipelineStateIdle] until the first signal
/// arrives from Rust.
final pipelineStateProvider = StreamProvider<PipelineState>((ref) {
  return PipelineStateChanged.rustSignalStream.map(
    (signalPack) => signalPack.message.newState,
  );
});
