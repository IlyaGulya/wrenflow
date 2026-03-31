import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:rinf/rinf.dart';
import 'package:window_manager/window_manager.dart';

import 'providers/app_lifecycle_provider.dart';
import 'providers/overlay_controller.dart';
import 'screens/settings_screen.dart';
import 'screens/setup_wizard_screen.dart';
import 'src/bindings/bindings.dart';
import 'state/app_lifecycle_state.dart';
import 'theme/wrenflow_theme.dart';
import 'widgets/system_tray.dart';
import 'widgets/window_synchronizer.dart';

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

  // Initialize system tray — it listens to lifecycle + pipeline state.
  final tray = SystemTrayManager(container);
  tray.init();

  // Initialize native overlay controller — bridges pipeline state to NSPanel.
  final overlay = OverlayController(container);
  overlay.init();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        title: 'Wrenflow',
        debugShowCheckedModeBanner: false,
        theme: WrenflowStyle.themeData,
        home: const WindowSynchronizer(
          child: _AppHome(),
        ),
      ),
    ),
  );
}

// ── App home — declarative projection of lifecycle state ──────

class _AppHome extends ConsumerWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lifecycle = ref.watch(appLifecycleProvider);
    final activeScreen = ref.watch(activeScreenProvider);

    return switch (lifecycle) {
      Initializing() => const Scaffold(
          backgroundColor: WrenflowStyle.surface,
        ),
      Onboarding() => const SetupWizardScreen(
          mode: WizardMode.onboarding,
        ),
      PermissionRecovery() => const SetupWizardScreen(
          mode: WizardMode.recovery,
        ),
      Running() => switch (activeScreen) {
          ActiveScreen.settings => SettingsScreen(
              initialTab: ref.watch(settingsInitialTabProvider),
            ),
          ActiveScreen.none => const Scaffold(
              backgroundColor: WrenflowStyle.surface,
            ),
        },
      ShuttingDown() => const Scaffold(
          backgroundColor: WrenflowStyle.surface,
        ),
    };
  }
}
