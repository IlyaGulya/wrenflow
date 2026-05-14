import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/wrenflow_theme.dart';
import 'main_window_presentation.dart';

abstract class WindowShell {
  bool get isSupported;
  Future<void> initializeMainWindow();
  void addListener(WindowListener listener);
  void removeListener(WindowListener listener);
  Future<void> show(MainWindowPresentation presentation);
  Future<void> refresh(MainWindowPresentation presentation);
  Future<void> hide(MainWindowPresentation presentation);
  Future<void> syncHidden(MainWindowPresentation presentation);
}

const _appPolicyChannel = MethodChannel('dev.gulya.wrenflow/app_policy');

WindowShell get platformWindowShell {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return const _MacOsWindowShell();
  }
  return const _UnsupportedWindowShell();
}

class _MacOsWindowShell implements WindowShell {
  const _MacOsWindowShell();

  @override
  bool get isSupported => true;

  @override
  Future<void> initializeMainWindow() async {
    await WindowManipulator.initialize();
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(340, 380));
    await windowManager.setMinimumSize(const Size(300, 340));
    await windowManager.setTitle('');
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setBackgroundColor(WrenflowStyle.surface);
    await windowManager.center();
    await windowManager.setSkipTaskbar(true);
    await windowManager.setPreventClose(true);
  }

  @override
  void addListener(WindowListener listener) {
    windowManager.addListener(listener);
  }

  @override
  void removeListener(WindowListener listener) {
    windowManager.removeListener(listener);
  }

  @override
  Future<void> show(MainWindowPresentation presentation) async {
    await _setShowInDock(true);
    await windowManager.setSize(Size(presentation.width, presentation.height));
    await windowManager.setMinimumSize(const Size(300, 340));
    await windowManager.setSkipTaskbar(false);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
    WindowManipulator.setWindowAlphaValue(1.0);
  }

  @override
  Future<void> refresh(MainWindowPresentation presentation) async {
    await windowManager.setSize(Size(presentation.width, presentation.height));
    await windowManager.center();
    await windowManager.focus();
  }

  @override
  Future<void> hide(MainWindowPresentation presentation) async {
    WindowManipulator.setWindowAlphaValue(0.0);
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
    await _setShowInDock(false);
  }

  @override
  Future<void> syncHidden(MainWindowPresentation presentation) async {
    await windowManager.setSkipTaskbar(presentation.skipTaskbar);
  }

  Future<void> _setShowInDock(bool show) async {
    try {
      await _appPolicyChannel.invokeMethod('setShowInDock', {'show': show});
    } on MissingPluginException {
      // Platform channel not available.
    }
  }
}

class _UnsupportedWindowShell implements WindowShell {
  const _UnsupportedWindowShell();

  @override
  bool get isSupported => false;

  @override
  Future<void> initializeMainWindow() async {}

  @override
  void addListener(WindowListener listener) {}

  @override
  void removeListener(WindowListener listener) {}

  @override
  Future<void> show(MainWindowPresentation presentation) async {}

  @override
  Future<void> refresh(MainWindowPresentation presentation) async {}

  @override
  Future<void> hide(MainWindowPresentation presentation) async {}

  @override
  Future<void> syncHidden(MainWindowPresentation presentation) async {}
}
