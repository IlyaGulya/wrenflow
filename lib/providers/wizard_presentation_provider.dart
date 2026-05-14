import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/shell_capabilities.dart';
import '../state/app_lifecycle_state.dart';
import 'app_lifecycle_provider.dart';
import 'launch_at_login_provider.dart';
import 'permissions_provider.dart';

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
  final MissingPermissions? recoveryMissing;
}

final wizardPresentationProvider =
    Provider.family<WizardPresentation, WizardMode>((ref, mode) {
      final lifecycle = ref.watch(appLifecycleProvider);
      final permissions = ref.watch(permissionsProvider);
      final shellCapabilities = ref.watch(shellCapabilitiesProvider);
      final launchAtLogin = ref.watch(launchAtLoginProvider);

      final currentStep = lifecycle is Onboarding
          ? lifecycle.currentStep
          : OnboardingStep.microphone;

      final canAdvance = switch (currentStep) {
        OnboardingStep.microphone =>
          permissions.microphone == PermissionUiStatus.granted,
        OnboardingStep.accessibility =>
          permissions.accessibility == PermissionUiStatus.granted,
        _ => true,
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
        recoveryMissing: lifecycle is PermissionRecovery ? lifecycle.missing : null,
      );
    });
