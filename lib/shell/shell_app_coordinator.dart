import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'overlay_controller.dart';
import 'shell_runtime.dart';
import 'system_tray.dart';

/// Owns non-UI shell startup work for the desktop app.
class ShellAppCoordinator {
  ShellAppCoordinator(this._container);

  final ProviderContainer _container;

  late final ShellRuntimeCoordinator _runtime =
      ShellRuntimeCoordinator(_container);
  late final SystemTrayManager _tray = SystemTrayManager(_container);
  late final OverlayController _overlay = OverlayController(_container);

  Future<void> init() async {
    await _runtime.init();
    await _tray.init();
    _overlay.init();
  }
}
