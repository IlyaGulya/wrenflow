import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/app_lifecycle_provider.dart';
import 'main_window_presentation.dart';
import 'window_shell.dart';

/// Sits at the root of the widget tree. Watches lifecycle state and
/// applies window configuration changes as reactive side effects.
///
/// Handles flash-free startup by waiting for the first frame to render
/// before making the window visible.
class WindowSynchronizer extends ConsumerStatefulWidget {
  const WindowSynchronizer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowSynchronizer> createState() => _WindowSynchronizerState();
}

class _WindowSynchronizerState extends ConsumerState<WindowSynchronizer>
    with WindowListener {
  bool _hasRenderedFirstFrame = false;
  bool _isWindowVisible = false;

  @override
  void initState() {
    super.initState();
    platformWindowShell.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hasRenderedFirstFrame = true;
      _syncWindow();
    });
  }

  @override
  void dispose() {
    platformWindowShell.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<MainWindowPresentation>(mainWindowPresentationProvider, (
      prev,
      next,
    ) {
      _syncWindow();
    });

    return widget.child;
  }

  Future<void> _syncWindow() async {
    final presentation = ref.read(mainWindowPresentationProvider);

    if (presentation.visible && !_isWindowVisible && _hasRenderedFirstFrame) {
      await platformWindowShell.show(presentation);
      _isWindowVisible = true;
    } else if (presentation.visible && _isWindowVisible) {
      await platformWindowShell.refresh(presentation);
    } else if (!presentation.visible && _isWindowVisible) {
      await platformWindowShell.hide(presentation);
      _isWindowVisible = false;
    } else if (!presentation.visible && !_isWindowVisible) {
      await platformWindowShell.syncHidden(presentation);
    }
  }

  @override
  void onWindowClose() {
    final navigation = ref.read(mainWindowNavigationProvider);
    if (navigation.showsSettings) {
      ref.read(mainWindowNavigationProvider.notifier).close();
    } else {
      ref.read(appLifecycleProvider.notifier).quit();
    }
  }
}
