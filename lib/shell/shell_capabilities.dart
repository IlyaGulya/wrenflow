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

class ShellCapabilitiesNotifier
    extends RustSnapshotNotifier<ShellCapabilities> {
  @override
  ShellCapabilities build() {
    bindRustSnapshotState<ShellCapabilitiesSnapshotChanged>(
      requestSnapshot: () =>
          const RequestShellCapabilitiesSnapshot().sendSignalToRust(),
      signalStream: ShellCapabilitiesSnapshotChanged.rustSignalStream,
      map: (message) {
        final snapshot = message.snapshot;
        return ShellCapabilities(
          launchAtLogin: snapshot.launchAtLogin,
          updates: snapshot.updates,
          localTranscription: snapshot.localTranscription,
          microphoneSelection: snapshot.microphoneSelection,
          tray: snapshot.tray,
          overlays: snapshot.overlays,
        );
      },
    );
    return _detectLocalCapabilities();
  }

  void reportLocalCapabilities() {
    final localSnapshot = _detectLocalCapabilities();
    state = localSnapshot;
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

    // Current shell/runtime integration is only implemented and packaged for
    // macOS. Keep this honest until real adapters and packaging exist for
    // other platforms.
    if (!Platform.isMacOS) {
      return const ShellCapabilities(
        launchAtLogin: false,
        updates: false,
        localTranscription: false,
        microphoneSelection: false,
        tray: false,
        overlays: false,
      );
    }

    return const ShellCapabilities(
      launchAtLogin: true,
      updates: true,
      localTranscription: true,
      microphoneSelection: true,
      tray: true,
      overlays: true,
    );
  }
}

final shellCapabilitiesProvider =
    NotifierProvider<ShellCapabilitiesNotifier, ShellCapabilities>(
      ShellCapabilitiesNotifier.new,
    );
