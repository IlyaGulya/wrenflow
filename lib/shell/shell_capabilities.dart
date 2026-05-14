import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/bindings/signals/signals.dart';
import '../providers/rust_snapshot_bridge.dart';

class ShellCapabilities {
  const ShellCapabilities({
    required this.launchAtLogin,
    required this.updates,
    required this.localTranscription,
    required this.microphoneSelection,
    required this.tray,
    required this.overlays,
  });

  final bool launchAtLogin;
  final bool updates;
  final bool localTranscription;
  final bool microphoneSelection;
  final bool tray;
  final bool overlays;
}

class ShellCapabilitiesNotifier extends Notifier<ShellCapabilities> {
  StreamSubscription? _snapshotSub;

  @override
  ShellCapabilities build() {
    final localSnapshot = _detectLocalCapabilities();
    _snapshotSub = bindRustSnapshot<ShellCapabilitiesSnapshotChanged>(
      requestSnapshot: () =>
          const RequestShellCapabilitiesSnapshot().sendSignalToRust(),
      signalStream: ShellCapabilitiesSnapshotChanged.rustSignalStream,
      onMessage: (message) {
        final snapshot = message.snapshot;
        state = ShellCapabilities(
          launchAtLogin: snapshot.launchAtLogin,
          updates: snapshot.updates,
          localTranscription: snapshot.localTranscription,
          microphoneSelection: snapshot.microphoneSelection,
          tray: snapshot.tray,
          overlays: snapshot.overlays,
        );
      },
    );

    ReportShellCapabilitiesSnapshot(
      snapshot: ShellCapabilitiesSnapshot(
        launchAtLogin: localSnapshot.launchAtLogin,
        updates: localSnapshot.updates,
        localTranscription: localSnapshot.localTranscription,
        microphoneSelection: localSnapshot.microphoneSelection,
        tray: localSnapshot.tray,
        overlays: localSnapshot.overlays,
      ),
    ).sendSignalToRust();

    ref.onDispose(() => _snapshotSub?.cancel());
    return localSnapshot;
  }

  ShellCapabilities _detectLocalCapabilities() {
    if (kIsWeb) {
      return const ShellCapabilities(
        launchAtLogin: false,
        updates: false,
        localTranscription: false,
        microphoneSelection: false,
        tray: false,
        overlays: false,
      );
    }

    return ShellCapabilities(
      launchAtLogin: Platform.isMacOS,
      updates: !Platform.isIOS && !Platform.isAndroid,
      localTranscription: !Platform.isIOS && !Platform.isAndroid,
      microphoneSelection:
          Platform.isMacOS || Platform.isWindows || Platform.isLinux,
      tray: Platform.isMacOS || Platform.isWindows || Platform.isLinux,
      overlays: Platform.isMacOS,
    );
  }
}

final shellCapabilitiesProvider =
    NotifierProvider<ShellCapabilitiesNotifier, ShellCapabilities>(
      ShellCapabilitiesNotifier.new,
    );
