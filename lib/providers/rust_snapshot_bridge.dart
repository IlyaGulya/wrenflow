import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

abstract class RustSnapshotNotifier<TState> extends Notifier<TState> {
  final List<StreamSubscription<Object?>> _rustSnapshotSubscriptions = [];
  bool _disposeHookRegistered = false;

  @protected
  void bindRustSnapshotSignal<TSignal>({
    required void Function() requestSnapshot,
    required Stream<RustSignalPack<TSignal>> signalStream,
    required void Function(TSignal message) onMessage,
  }) {
    _ensureDisposeHook();
    final sub = bindRustSnapshot<TSignal>(
      requestSnapshot: requestSnapshot,
      signalStream: signalStream,
      onMessage: onMessage,
    );
    _rustSnapshotSubscriptions.add(sub);
  }

  @protected
  void bindRustSnapshotState<TSignal>({
    required void Function() requestSnapshot,
    required Stream<RustSignalPack<TSignal>> signalStream,
    required TState Function(TSignal message) map,
  }) {
    bindRustSnapshotSignal<TSignal>(
      requestSnapshot: requestSnapshot,
      signalStream: signalStream,
      onMessage: (message) {
        state = map(message);
      },
    );
  }

  void _ensureDisposeHook() {
    if (_disposeHookRegistered) return;
    _disposeHookRegistered = true;
    ref.onDispose(() {
      for (final sub in _rustSnapshotSubscriptions) {
        unawaited(sub.cancel());
      }
      _rustSnapshotSubscriptions.clear();
    });
  }
}
