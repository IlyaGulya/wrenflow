import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
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

final shellCapabilitiesProvider = Provider<ShellCapabilities>((ref) {
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
});
