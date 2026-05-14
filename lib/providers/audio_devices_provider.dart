import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

class AudioDevicesSnapshotView {
  const AudioDevicesSnapshotView({
    required this.hasSnapshot,
    required this.devices,
    required this.defaultDeviceName,
    required this.selectedDeviceId,
    required this.effectiveSelectedDeviceId,
  });

  final bool hasSnapshot;
  final List<AudioDeviceInfo> devices;
  final String defaultDeviceName;
  final String selectedDeviceId;
  final String effectiveSelectedDeviceId;
}

final audioDevicesSnapshotProvider = StreamProvider<AudioDevicesSnapshotView>((
  ref,
) async* {
  const RequestAudioDevicesSnapshot().sendSignalToRust();

  yield* AudioDevicesSnapshotChanged.rustSignalStream.map((signalPack) {
    final snapshot = signalPack.message.snapshot;
    return AudioDevicesSnapshotView(
      hasSnapshot: snapshot.hasSnapshot,
      devices: snapshot.devices,
      defaultDeviceName: snapshot.defaultDeviceName,
      selectedDeviceId: snapshot.selectedDeviceId,
      effectiveSelectedDeviceId: snapshot.effectiveSelectedDeviceId,
    );
  });
});
