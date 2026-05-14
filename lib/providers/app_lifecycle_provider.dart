import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_provider.dart';
import '../src/bindings/signals/signals.dart' as sig;
import '../state/app_lifecycle_state.dart';
import 'rust_snapshot_bridge.dart';

/// Projects the Rust-owned app session FSM into Flutter and forwards user
/// intents back to Rust.
class AppLifecycleNotifier extends RustSnapshotNotifier<AppLifecycleState> {
  @override
  AppLifecycleState build() {
    _startSnapshotBridge();
    return const Initializing();
  }

  void _startSnapshotBridge() {
    bindRustSnapshotSignal<sig.AppSessionSnapshotChanged>(
      requestSnapshot: () =>
          const sig.RequestAppSessionSnapshot().sendSignalToRust(),
      signalStream: sig.AppSessionSnapshotChanged.rustSignalStream,
      onMessage: (message) {
        _transitionTo(_mapSignalState(message.state));
      },
    );
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
    await ref.read(settingsProvider.notifier).setHasCompletedSetup(true);
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
