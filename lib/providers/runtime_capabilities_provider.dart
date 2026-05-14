import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

import 'rust_snapshot_bridge.dart';

class RuntimeCapabilities {
  const RuntimeCapabilities({
    required this.globalHotkey,
    required this.pasteInjection,
    required this.localTranscription,
    required this.audioCapture,
    required this.modelDownload,
    required this.modelActivation,
    required this.historyPersistence,
  });

  final bool globalHotkey;
  final bool pasteInjection;
  final bool localTranscription;
  final bool audioCapture;
  final bool modelDownload;
  final bool modelActivation;
  final bool historyPersistence;
}

final runtimeCapabilitiesProvider = StreamProvider<RuntimeCapabilities>(
  (ref) => rustSnapshotStream(
    requestSnapshot: () =>
        const RequestRuntimeCapabilitiesSnapshot().sendSignalToRust(),
    signalStream: RuntimeCapabilitiesSnapshotChanged.rustSignalStream,
    map: (message) {
      final snapshot = message.snapshot;
      return RuntimeCapabilities(
        globalHotkey: snapshot.globalHotkey,
        pasteInjection: snapshot.pasteInjection,
        localTranscription: snapshot.localTranscription,
        audioCapture: snapshot.audioCapture,
        modelDownload: snapshot.modelDownload,
        modelActivation: snapshot.modelActivation,
        historyPersistence: snapshot.historyPersistence,
      );
    },
  ),
);
