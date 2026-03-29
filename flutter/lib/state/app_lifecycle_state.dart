import 'package:flutter/foundation.dart';

/// Which permissions are currently missing.
@immutable
class MissingPermissions {
  const MissingPermissions({
    required this.microphone,
    required this.accessibility,
  });

  /// true = this permission is missing.
  final bool microphone;
  final bool accessibility;

  bool get any => microphone || accessibility;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MissingPermissions &&
          other.microphone == microphone &&
          other.accessibility == accessibility;

  @override
  int get hashCode => Object.hash(microphone, accessibility);
}

/// Steps in the onboarding wizard.
enum OnboardingStep {
  microphone,
  accessibility,
  hotkey,
  vocabulary,
  complete;
}

/// How the wizard is being used.
enum WizardMode {
  /// First launch — all 5 steps.
  onboarding,

  /// Permissions lost — only missing permission steps, then auto-return.
  recovery,
}

/// Top-level app lifecycle state. Single source of truth.
sealed class AppLifecycleState {
  const AppLifecycleState();
}

/// Checking prefs + permissions. No windows visible yet.
class Initializing extends AppLifecycleState {
  const Initializing();
}

/// First-time setup wizard.
class Onboarding extends AppLifecycleState {
  const Onboarding({required this.currentStep});

  final OnboardingStep currentStep;

  Onboarding copyWith({OnboardingStep? currentStep}) =>
      Onboarding(currentStep: currentStep ?? this.currentStep);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Onboarding && other.currentStep == currentStep;

  @override
  int get hashCode => currentStep.hashCode;
}

/// Permissions were revoked while running. Shows recovery wizard.
/// Auto-transitions back to Running when permissions restored.
class PermissionRecovery extends AppLifecycleState {
  const PermissionRecovery({required this.missing});

  final MissingPermissions missing;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PermissionRecovery && other.missing == missing;

  @override
  int get hashCode => missing.hashCode;
}

/// Normal operation. Main window hidden, tray active.
class Running extends AppLifecycleState {
  const Running();
}

/// App is shutting down.
class ShuttingDown extends AppLifecycleState {
  const ShuttingDown();
}
