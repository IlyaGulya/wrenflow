import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/permissions_provider.dart';
import '../src/bindings/signals/signals.dart';
import '../state/app_lifecycle_state.dart';
import '../widgets/system_tray.dart';

const _kHasCompletedSetup = 'has_completed_setup';

/// Manages the app lifecycle state machine.
class AppLifecycleNotifier extends Notifier<AppLifecycleState> {
  /// Consecutive polls with missing permissions before triggering recovery.
  static const _permissionLostThreshold = 3;
  int _permissionLostCount = 0;

  @override
  AppLifecycleState build() {
    ref.listen<PermissionsState>(permissionsProvider, _onPermissionsChanged);
    _initialize();
    return const Initializing();
  }

  void _transitionTo(AppLifecycleState newState) {
    state = newState;
    // Sync transcript action with Rust based on lifecycle.
    final action = newState is Running ? 'paste' : 'display_only';
    SetTranscriptAction(action: action).sendSignalToRust();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final hasCompleted = prefs.getBool(_kHasCompletedSetup) ?? false;

    // Start model download/load in background immediately.
    const InitializeLocalModel().sendSignalToRust();

    if (!hasCompleted) {
      _transitionTo(const Onboarding(currentStep: OnboardingStep.microphone));
      return;
    }

    final permissions = ref.read(permissionsProvider);
    if (permissions.allGranted) {
      _transitionTo(const Running());
    } else {
      _transitionTo(PermissionRecovery(missing: _buildMissing(permissions)));
    }
  }

  // ── Permission monitoring ─────────────────────────────────

  void _onPermissionsChanged(PermissionsState? prev, PermissionsState next) {
    final current = state;

    // Running → PermissionRecovery (debounced)
    if (current is Running && !next.allGranted) {
      _permissionLostCount++;
      if (_permissionLostCount >= _permissionLostThreshold) {
        _transitionTo(PermissionRecovery(missing: _buildMissing(next)));
        _permissionLostCount = 0;
      }
    } else if (current is Running) {
      _permissionLostCount = 0;
    }

    // PermissionRecovery → Running (auto)
    if (current is PermissionRecovery && next.allGranted) {
      _transitionTo(const Running());
      _permissionLostCount = 0;
    }
  }

  MissingPermissions _buildMissing(PermissionsState p) {
    return MissingPermissions(
      microphone: p.microphone != PermissionStatus.granted,
      accessibility: p.accessibility != PermissionStatus.granted,
    );
  }

  // ── Onboarding actions ────────────────────────────────────

  void onboardingNext() {
    final current = state;
    if (current is! Onboarding) return;
    final nextIndex = current.currentStep.index + 1;
    if (nextIndex < OnboardingStep.values.length) {
      state = current.copyWith(currentStep: OnboardingStep.values[nextIndex]);
    }
  }

  void onboardingBack() {
    final current = state;
    if (current is! Onboarding) return;
    if (current.currentStep.index > 0) {
      state = current.copyWith(
        currentStep: OnboardingStep.values[current.currentStep.index - 1],
      );
    }
  }

  Future<void> completeOnboarding() async {
    if (state is! Onboarding) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHasCompletedSetup, true);
    _transitionTo(const Running());
  }

  // ── Global actions ────────────────────────────────────────

  void quit() {
    _transitionTo(const ShuttingDown());
    // Give a frame for cleanup, then exit.
    WidgetsBinding.instance.addPostFrameCallback((_) => exit(0));
  }
}

final appLifecycleProvider =
    NotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
  AppLifecycleNotifier.new,
);

// ── Derived providers ─────────────────────────────────────────

/// Main window configuration derived from lifecycle state.
@immutable
class MainWindowConfig {
  const MainWindowConfig({
    required this.visible,
    required this.skipTaskbar,
  });

  final bool visible;
  final bool skipTaskbar;
}

MainWindowConfig _configFor(AppLifecycleState state, bool hasSubWindows) {
  return switch (state) {
    Initializing() => const MainWindowConfig(visible: false, skipTaskbar: true),
    Onboarding() => const MainWindowConfig(visible: true, skipTaskbar: false),
    PermissionRecovery() =>
      const MainWindowConfig(visible: true, skipTaskbar: false),
    Running() => MainWindowConfig(visible: false, skipTaskbar: !hasSubWindows),
    ShuttingDown() => const MainWindowConfig(visible: false, skipTaskbar: true),
  };
}

final mainWindowConfigProvider = Provider<MainWindowConfig>((ref) {
  // Import is deferred — provider is in system_tray.dart
  final hasSubWindows = ref.watch(hasOpenSubWindowsProvider);
  return _configFor(ref.watch(appLifecycleProvider), hasSubWindows);
});

final subWindowsAllowedProvider = Provider<bool>((ref) {
  return ref.watch(appLifecycleProvider) is Running;
});
