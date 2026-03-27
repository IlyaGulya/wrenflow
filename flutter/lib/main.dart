import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rinf/rinf.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/setup_wizard_screen.dart';
import 'src/bindings/bindings.dart';
import 'widgets/system_tray.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize window manager to control window visibility and dock behavior.
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(400, 300),
    minimumSize: Size(300, 200),
    skipTaskbar: true, // Hide from dock — menu bar only.
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Hide the main window on startup; the app lives in the menu bar.
    await windowManager.hide();
  });

  await initializeRust(assignRustSignal);

  final container = ProviderContainer();

  // Initialize the system tray (menu bar icon + context menu).
  final systemTray = SystemTrayManager(container);
  await systemTray.init();

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const _AppHome(),
    );
  }
}

/// Root widget that checks whether onboarding has been completed and shows
/// either the setup wizard or the main home page.
class _AppHome extends ConsumerWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setupAsync = ref.watch(hasCompletedSetupProvider);

    return setupAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const MyHomePage(title: 'Wrenflow'),
      data: (hasCompleted) {
        if (hasCompleted) {
          return const MyHomePage(title: 'Wrenflow');
        }
        return SetupWizardScreen(
          onComplete: () {
            // Invalidate so we re-read from shared_preferences.
            ref.invalidate(hasCompletedSetupProvider);
          },
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
