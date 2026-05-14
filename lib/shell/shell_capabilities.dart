import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/bindings/signals/signals.dart';
import '../providers/rust_snapshot_bridge.dart';
import 'launch_at_login_shell.dart';
import 'overlay_shell.dart';
import 'permissions_shell.dart';
import 'tray_shell.dart';
import 'window_shell.dart';

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

    final supportsWindowShell = platformWindowShell.isSupported;
    final supportsPermissions = platformPermissionsShell.isSupported;
    final supportsLaunchAtLogin = platformLaunchAtLoginShell.isSupported;
    final supportsTray = platformTrayShell.isSupported;
    final supportsOverlays = platformOverlayShell.isSupported;
    final supportsDesktopShell =
        supportsWindowShell && supportsPermissions && supportsTray;

    return ShellCapabilities(
      launchAtLogin: supportsLaunchAtLogin,
      updates: supportsDesktopShell,
      localTranscription: supportsDesktopShell,
      microphoneSelection: supportsDesktopShell,
      tray: supportsTray,
      overlays: supportsOverlays,
    );
  }
}

final shellCapabilitiesProvider =
    NotifierProvider<ShellCapabilitiesNotifier, ShellCapabilities>(
      ShellCapabilitiesNotifier.new,
    );
