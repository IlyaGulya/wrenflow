import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:rinf/rinf.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_lifecycle_provider.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/setup_wizard_screen.dart';
import 'src/bindings/bindings.dart';
import 'state/app_lifecycle_state.dart';
import 'theme/wrenflow_theme.dart';
import 'widgets/system_tray.dart';
import 'widgets/window_synchronizer.dart';

Future<void> main(List<String> args) async {
  if (args.firstOrNull == 'multi_window') {
    await _runSubWindow(args);
    return;
  }
  await _runMainWindow();
}

// ── Sub-window entry point ────────────────────────────────────

Future<void> _runSubWindow(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final windowArgs = args.length > 2 ? args[2] : '{}';
  final parsed = jsonDecode(windowArgs) as Map<String, dynamic>;
  final windowType = parsed['type'] as String? ?? 'unknown';

  runApp(
    ProviderScope(
      child: _SubWindowApp(windowType: windowType),
    ),
  );
}

class _SubWindowApp extends StatelessWidget {
  const _SubWindowApp({required this.windowType});

  final String windowType;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wrenflow',
      debugShowCheckedModeBanner: false,
      theme: WrenflowStyle.themeData,
      home: switch (windowType) {
        'settings' => const SettingsScreen(),
        'history' => const HistoryScreen(),
        _ => const Scaffold(body: Center(child: Text('Unknown window'))),
      },
    );
  }
}

// ── Main window entry point ──────────────────────────────────

Future<void> _runMainWindow() async {
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

  await initializeRust(assignRustSignal);

  final container = ProviderContainer();

  // Initialize system tray — it listens to lifecycle + pipeline state.
  final tray = SystemTrayManager(container);
  tray.init();

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
      Running() => const Scaffold(
          backgroundColor: WrenflowStyle.surface,
        ),
      ShuttingDown() => const Scaffold(
          backgroundColor: WrenflowStyle.surface,
        ),
    };
  }
}
