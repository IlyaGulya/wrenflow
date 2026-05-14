import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/settings_screen.dart';
import '../src/bindings/signals/signals.dart' as sig;
import '../state/app_lifecycle_state.dart';

const _kHasCompletedSetup = 'has_completed_setup';

/// Projects the Rust-owned app session FSM into Flutter and forwards user
/// intents back to Rust.
class AppLifecycleNotifier extends Notifier<AppLifecycleState> {
  StreamSubscription? _snapshotSub;

  @override
  AppLifecycleState build() {
    _startSnapshotBridge();
    _bootstrap();
    ref.onDispose(() => _snapshotSub?.cancel());
    return const Initializing();
  }

  void _startSnapshotBridge() {
    _snapshotSub = sig.AppSessionSnapshotChanged.rustSignalStream.listen((
      signalPack,
    ) {
      _transitionTo(_mapSignalState(signalPack.message.state));
    });

    const sig.RequestAppSessionSnapshot().sendSignalToRust();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final hasCompleted = prefs.getBool(_kHasCompletedSetup) ?? false;
    sig.BootstrapAppSession(hasCompletedSetup: hasCompleted).sendSignalToRust();
  }

  AppLifecycleState _mapSignalState(sig.AppSessionState state) {
    return switch (state) {
      sig.AppSessionStateInitializing() => const Initializing(),
      sig.AppSessionStateOnboarding() => Onboarding(
        currentStep: _mapOnboardingStep(state.step),
      ),
      sig.AppSessionStatePermissionRecovery() => PermissionRecovery(
        missing: MissingPermissions(
          microphone: state.microphoneMissing,
          accessibility: state.accessibilityMissing,
        ),
      ),
      sig.AppSessionStateReady() => const Running(),
      sig.AppSessionStateShuttingDown() => const ShuttingDown(),
      _ => const Initializing(),
    };
  }

  OnboardingStep _mapOnboardingStep(sig.AppSessionOnboardingStep step) {
    return switch (step) {
      sig.AppSessionOnboardingStep.microphone => OnboardingStep.microphone,
      sig.AppSessionOnboardingStep.accessibility =>
        OnboardingStep.accessibility,
      sig.AppSessionOnboardingStep.hotkey => OnboardingStep.hotkey,
      sig.AppSessionOnboardingStep.model => OnboardingStep.model,
      sig.AppSessionOnboardingStep.vocabulary => OnboardingStep.vocabulary,
      sig.AppSessionOnboardingStep.complete => OnboardingStep.complete,
    };
  }

  void _transitionTo(AppLifecycleState newState) {
    state = newState;
    final action = newState is Running ? 'paste' : 'display_only';
    sig.SetTranscriptAction(action: action).sendSignalToRust();
  }

  // ── Onboarding actions ────────────────────────────────────

  void onboardingNext() {
    const sig.AdvanceOnboarding().sendSignalToRust();
  }

  void onboardingBack() {
    const sig.RetreatOnboarding().sendSignalToRust();
  }

  Future<void> completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHasCompletedSetup, true);
    const sig.CompleteOnboarding().sendSignalToRust();
  }

  // ── Global actions ────────────────────────────────────────

  void quit() {
    const sig.RequestQuit().sendSignalToRust();
  }
}

final appLifecycleProvider =
    NotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
      AppLifecycleNotifier.new,
    );

// ── Active screen (settings shown in main window) ─────────────

enum ActiveScreen { none, settings }

class ActiveScreenNotifier extends Notifier<ActiveScreen> {
  @override
  ActiveScreen build() => ActiveScreen.none;

  void show(ActiveScreen screen) => state = screen;
  void close() => state = ActiveScreen.none;
}

/// Which settings tab to show when settings opens.
class SettingsInitialTabNotifier extends Notifier<SettingsTab> {
  @override
  SettingsTab build() => SettingsTab.general;

  void set(SettingsTab tab) => state = tab;
}

final settingsInitialTabProvider =
    NotifierProvider<SettingsInitialTabNotifier, SettingsTab>(
      SettingsInitialTabNotifier.new,
    );

final activeScreenProvider =
    NotifierProvider<ActiveScreenNotifier, ActiveScreen>(
      ActiveScreenNotifier.new,
    );

// ── Derived providers ─────────────────────────────────────────

/// Main window configuration derived from lifecycle state + active screen.
@immutable
class MainWindowConfig {
  const MainWindowConfig({
    required this.visible,
    required this.skipTaskbar,
    this.width = 340,
    this.height = 380,
  });

  final bool visible;
  final bool skipTaskbar;
  final double width;
  final double height;
}

MainWindowConfig _configFor(AppLifecycleState state, ActiveScreen screen) {
  return switch (state) {
    Initializing() => const MainWindowConfig(visible: false, skipTaskbar: true),
    Onboarding() => const MainWindowConfig(visible: true, skipTaskbar: false),
    PermissionRecovery() => const MainWindowConfig(
      visible: true,
      skipTaskbar: false,
    ),
    Running() => switch (screen) {
      ActiveScreen.settings => const MainWindowConfig(
        visible: true,
        skipTaskbar: false,
        width: 720,
        height: 520,
      ),
      ActiveScreen.none => const MainWindowConfig(
        visible: false,
        skipTaskbar: true,
      ),
    },
    ShuttingDown() => const MainWindowConfig(visible: false, skipTaskbar: true),
  };
}

final mainWindowConfigProvider = Provider<MainWindowConfig>((ref) {
  final screen = ref.watch(activeScreenProvider);
  return _configFor(ref.watch(appLifecycleProvider), screen);
});
