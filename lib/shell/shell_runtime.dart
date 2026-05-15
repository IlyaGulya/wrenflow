import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/launch_at_login_provider.dart';
import '../providers/permissions_provider.dart';
import 'shell_capabilities.dart';
import 'launch_at_login_shell.dart';
import 'permissions_shell.dart';

/// Bootstraps shell-owned bridges explicitly at startup instead of relying on
/// lazy UI reads to start polling or report capabilities.
class ShellRuntimeCoordinator {
  ShellRuntimeCoordinator(this._container);

  final ProviderContainer _container;

  Future<void> init() async {
    final capabilitiesNotifier = _container.read(
      shellCapabilitiesProvider.notifier,
    );
    capabilitiesNotifier.reportLocalCapabilities();

    if (platformPermissionsShell.isSupported) {
      await _container.read(permissionsProvider.notifier).startMonitoring();
    }
    if (platformLaunchAtLoginShell.isSupported) {
      await _container.read(launchAtLoginProvider.notifier).refresh();
    }
  }
}
