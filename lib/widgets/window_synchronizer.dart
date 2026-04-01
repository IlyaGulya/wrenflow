import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/app_lifecycle_provider.dart';

const _appPolicyChannel = MethodChannel('dev.gulya.wrenflow/app_policy');

/// Sits at the root of the widget tree. Watches lifecycle state and
/// applies window configuration changes as reactive side effects.
///
/// Handles flash-free startup by waiting for the first frame to render
/// before making the window visible.
class WindowSynchronizer extends ConsumerStatefulWidget {
  const WindowSynchronizer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowSynchronizer> createState() =>
      _WindowSynchronizerState();
}

class _WindowSynchronizerState extends ConsumerState<WindowSynchronizer>
    with WindowListener {
  bool _hasRenderedFirstFrame = false;
  bool _isWindowVisible = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hasRenderedFirstFrame = true;
      _syncWindow();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<MainWindowConfig>(mainWindowConfigProvider, (prev, next) {
      _syncWindow();
    });

    return widget.child;
  }

  Future<void> _syncWindow() async {
    final config = ref.read(mainWindowConfigProvider);

    if (config.visible && !_isWindowVisible && _hasRenderedFirstFrame) {
      await _setShowInDock(true);
      await windowManager.setSize(Size(config.width, config.height));
      await windowManager.setMinimumSize(const Size(300, 340));
      await windowManager.setSkipTaskbar(false);
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
      WindowManipulator.setWindowAlphaValue(1.0);
      _isWindowVisible = true;
    } else if (config.visible && _isWindowVisible) {
      await windowManager.setSize(Size(config.width, config.height));
      await windowManager.center();
      await windowManager.focus();
    } else if (!config.visible && _isWindowVisible) {
      WindowManipulator.setWindowAlphaValue(0.0);
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
      await _setShowInDock(false);
      _isWindowVisible = false;
    } else if (!config.visible && !_isWindowVisible) {
      await windowManager.setSkipTaskbar(config.skipTaskbar);
    }
  }

  Future<void> _setShowInDock(bool show) async {
    try {
      await _appPolicyChannel.invokeMethod('setShowInDock', {'show': show});
    } on MissingPluginException {
      // Platform channel not available (non-macOS).
    }
  }

  // ── WindowListener: handle native close button ──────────────

  @override
  void onWindowClose() {
    final screen = ref.read(activeScreenProvider);
    if (screen != ActiveScreen.none) {
      // Close settings/history → hide window, stay running in tray.
      ref.read(activeScreenProvider.notifier).close();
    } else {
      // During onboarding/recovery, close button quits.
      ref.read(appLifecycleProvider.notifier).quit();
    }
  }
}
