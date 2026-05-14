import 'dart:async';

import 'package:rinf/rinf.dart';

Stream<TState> rustSnapshotStream<TSignal, TState>({
  required void Function() requestSnapshot,
  required Stream<RustSignalPack<TSignal>> signalStream,
  required TState Function(TSignal message) map,
}) {
  return Stream.multi((controller) {
    final sub = signalStream.listen(
      (signalPack) => controller.add(map(signalPack.message)),
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = () => sub.cancel();
    requestSnapshot();
  });
}

StreamSubscription<RustSignalPack<TSignal>> bindRustSnapshot<TSignal>({
  required void Function() requestSnapshot,
  required Stream<RustSignalPack<TSignal>> signalStream,
  required void Function(TSignal message) onMessage,
}) {
  final sub = signalStream.listen(
    (signalPack) => onMessage(signalPack.message),
  );
  requestSnapshot();
  return sub;
}
