import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:rinf/rinf.dart';
import 'package:window_manager/window_manager.dart';

import 'providers/settings_provider.dart';
import 'screens/settings_screen.dart';
import 'shell/shell_app_coordinator.dart';
import 'shell/main_window_presentation.dart';
import 'shell/window_synchronizer.dart';
import 'services/app_version.dart';
import 'screens/setup_wizard_screen.dart';
import 'src/bindings/bindings.dart';
import 'state/app_lifecycle_state.dart';
import 'theme/wrenflow_theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await WindowManipulator.initialize();
  await windowManager.ensureInitialized();

  // Pre-configure window. It stays hidden (alpha=0 from native side)
  // until WindowSynchronizer reveals it after first frame + state ready.
  await windowManager.setSize(const Size(340, 380));
  await windowManager.setMinimumSize(const Size(300, 340));
  await windowManager.setTitle('');
  await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  await windowManager.setBackgroundColor(WrenflowStyle.surface);
  await windowManager.center();
  await windowManager.setSkipTaskbar(true);
  await windowManager.setPreventClose(true);

  await initializeRust(assignRustSignal);

  final container = ProviderContainer();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        title: 'Wrenflow',
        debugShowCheckedModeBanner: false,
        theme: WrenflowStyle.themeData,
        home: const WindowSynchronizer(child: _AppHome()),
      ),
    ),
  );

  unawaited(_initializeApp(container));
}

Future<void> _initializeApp(ProviderContainer container) async {
  await AppVersion.load();

  container.read(settingsProvider);
  final shell = ShellAppCoordinator(container);
  await shell.init();
}

// ── App home — declarative projection of lifecycle state ──────

class _AppHome extends ConsumerWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presentation = ref.watch(mainWindowPresentationProvider);

    return switch (presentation.content) {
      MainWindowContent.splash => const Scaffold(
        backgroundColor: WrenflowStyle.surface,
      ),
      MainWindowContent.onboarding => const SetupWizardScreen(
        mode: WizardMode.onboarding,
      ),
      MainWindowContent.permissionRecovery => const SetupWizardScreen(
        mode: WizardMode.recovery,
      ),
      MainWindowContent.settings => SettingsScreen(
        initialTab: presentation.settingsTab,
      ),
      MainWindowContent.blank => const Scaffold(
        backgroundColor: WrenflowStyle.surface,
      ),
    };
  }
}
