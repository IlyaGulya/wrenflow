import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/shell_capabilities.dart';
import '../src/bindings/signals/signals.dart';
import '../state/app_lifecycle_state.dart';
import 'app_lifecycle_provider.dart';
import 'launch_at_login_provider.dart';
import 'local_models_snapshot_provider.dart';
import 'permissions_provider.dart';
import 'runtime_capabilities_provider.dart';

class WizardPresentation {
  const WizardPresentation({
    required this.lifecycle,
    required this.permissions,
    required this.currentStep,
    required this.canAdvance,
    required this.showGlobalModelIndicator,
    required this.showLaunchAtLogin,
    required this.launchAtLoginEnabled,
    required this.launchAtLoginLoading,
    this.launchAtLoginHint,
    this.hotkeyStepMessage,
    this.modelStepMessage,
    this.recoveryMissing,
  });

  final AppLifecycleState lifecycle;
  final PermissionsState permissions;
  final OnboardingStep currentStep;
  final bool canAdvance;
  final bool showGlobalModelIndicator;
  final bool showLaunchAtLogin;
  final bool launchAtLoginEnabled;
  final bool launchAtLoginLoading;
  final String? launchAtLoginHint;
  final String? hotkeyStepMessage;
  final String? modelStepMessage;
  final MissingPermissions? recoveryMissing;
}

final wizardPresentationProvider =
    Provider.family<WizardPresentation, WizardMode>((ref, mode) {
      final lifecycle = ref.watch(appLifecycleProvider);
      final permissions = ref.watch(permissionsProvider);
      final shellCapabilities = ref.watch(shellCapabilitiesProvider);
      final launchAtLogin = ref.watch(launchAtLoginProvider);
      final runtimeCapabilities = ref.watch(runtimeCapabilitiesProvider).value;
      final localModelsSnapshot = ref.watch(localModelsSnapshotProvider).value;

      final currentStep = lifecycle is Onboarding
          ? lifecycle.currentStep
          : OnboardingStep.microphone;

      final selectedModelId = localModelsSnapshot?.selectedModelId;
      final selectedModel = localModelsSnapshot?.findModel(selectedModelId);
      final selectedModelState = localModelsSnapshot?.stateFor(selectedModelId);
      final selectedModelReady =
          localModelsSnapshot != null &&
          selectedModelId != null &&
          localModelsSnapshot.activeModelId == selectedModelId &&
          selectedModelState is ModelStateReady;
      final selectedModelUnsupported =
          selectedModel != null && !selectedModel.supportsCurrentRuntime;

      final canAdvance = switch (currentStep) {
        OnboardingStep.microphone =>
          permissions.microphone == PermissionUiStatus.granted,
        OnboardingStep.accessibility =>
          permissions.accessibility == PermissionUiStatus.granted,
        OnboardingStep.hotkey => true,
        OnboardingStep.model =>
          runtimeCapabilities != null &&
                  (!runtimeCapabilities.localTranscription ||
                      !runtimeCapabilities.modelActivation)
              ? false
              : selectedModelReady,
        _ => true,
      };

      final hotkeyStepMessage = switch (runtimeCapabilities) {
        null => 'Loading runtime support...',
        RuntimeCapabilities(globalHotkey: false) =>
          'Global hotkeys are not available in the current runtime yet.',
        _ => null,
      };

      final modelStepMessage = switch (selectedModelState) {
        _ when runtimeCapabilities == null => 'Loading runtime support...',
        _ when runtimeCapabilities.localTranscription == false =>
          'Local transcription is not available in the current runtime yet.',
        _ when runtimeCapabilities.modelActivation == false =>
          'Model activation is not available in the current runtime yet.',
        null => 'Loading model catalog...',
        _ when selectedModelUnsupported =>
          '${selectedModel.displayName} is not supported by the current runtime.',
        ModelStateDownloading() => 'Wait for ${selectedModel?.displayName ?? 'the selected model'} to finish downloading.',
        ModelStateLoading() => 'Wait for ${selectedModel?.displayName ?? 'the selected model'} to finish loading.',
        ModelStateWarming() => 'Wait for ${selectedModel?.displayName ?? 'the selected model'} to finish warming up.',
        ModelStateError() => 'Fix the selected model from its card before continuing.',
        ModelStateReady() when selectedModelReady => null,
        _ => 'Use the selected model card to download or activate it before continuing.',
      };

      return WizardPresentation(
        lifecycle: lifecycle,
        permissions: permissions,
        currentStep: currentStep,
        canAdvance: canAdvance,
        showGlobalModelIndicator: currentStep != OnboardingStep.complete,
        showLaunchAtLogin:
            shellCapabilities.launchAtLogin &&
            currentStep == OnboardingStep.complete,
        launchAtLoginEnabled: launchAtLogin.enabled,
        launchAtLoginLoading: launchAtLogin.isLoading,
        launchAtLoginHint:
            launchAtLogin.unavailableReason ?? launchAtLogin.errorMessage,
        hotkeyStepMessage: currentStep == OnboardingStep.hotkey
            ? hotkeyStepMessage
            : null,
        modelStepMessage: currentStep == OnboardingStep.model
            ? modelStepMessage
            : null,
        recoveryMissing: lifecycle is PermissionRecovery ? lifecycle.missing : null,
      );
    });
