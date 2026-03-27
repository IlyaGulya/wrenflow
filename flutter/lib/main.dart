import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rinf/rinf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/setup_wizard_screen.dart';
import 'src/bindings/bindings.dart';
import 'theme/wrenflow_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Check if setup is completed before deciding window behavior.
  final prefs = await SharedPreferences.getInstance();
  final hasCompletedSetup = prefs.getBool('hasCompletedSetup') ?? false;

  // Initialize window manager.
  await windowManager.ensureInitialized();

  if (hasCompletedSetup) {
    // Setup done — hide window and Dock icon, menu bar only.
    const windowOptions = WindowOptions(
      size: Size(400, 300),
      minimumSize: Size(300, 200),
      skipTaskbar: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    });
  } else {
    // Setup wizard — borderless floating card, like original Swift app.
    const windowOptions = WindowOptions(
      size: Size(380, 520),
      minimumSize: Size(340, 400),
      center: true,
      title: '',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setSkipTaskbar(false);
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setHasShadow(false);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  await initializeRust(assignRustSignal);

  final container = ProviderContainer();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wrenflow',
      debugShowCheckedModeBanner: false,
      theme: WrenflowStyle.themeData,
      home: const _AppHome(),
    );
  }
}

class _AppHome extends ConsumerWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setupAsync = ref.watch(hasCompletedSetupProvider);

    return setupAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const Scaffold(
        body: Center(child: Text('Wrenflow')),
      ),
      data: (hasCompleted) {
        if (hasCompleted) {
          return const Scaffold(
            body: Center(child: Text('Wrenflow — Ready')),
          );
        }
        return SetupWizardScreen(
          onComplete: () {
            ref.invalidate(hasCompletedSetupProvider);
          },
        );
      },
    );
  }
}
