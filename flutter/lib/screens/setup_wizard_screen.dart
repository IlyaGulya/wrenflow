import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/permissions_provider.dart';
import '../providers/settings_provider.dart';
import '../services/permission_service.dart';

/// shared_preferences key for setup completion.
const _kHasCompletedSetup = 'has_completed_setup';

/// Provider that reads whether the user has completed onboarding.
final hasCompletedSetupProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kHasCompletedSetup) ?? false;
});

/// Available hotkey options for the push-to-talk trigger.
const _hotkeyOptions = <String, String>{
  'fn': 'Fn',
  'rightOption': 'Right Option',
  'f5': 'F5',
};

/// The steps in the setup wizard.
enum _SetupStep {
  microphone,
  accessibility,
  hotkey,
  vocabulary,
  complete;

  /// Human-readable step number (1-based).
  int get number => index + 1;

  /// Total number of steps.
  static int get totalSteps => values.length;
}

/// Multi-step onboarding wizard shown on first launch.
///
/// Walks the user through granting microphone and accessibility permissions,
/// selecting a hotkey, optionally entering custom vocabulary, and then
/// marks setup as complete in shared_preferences.
class SetupWizardScreen extends ConsumerStatefulWidget {
  const SetupWizardScreen({super.key, required this.onComplete});

  /// Called when the user finishes (or skips past) the wizard.
  final VoidCallback onComplete;

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen> {
  final _permissionService = PermissionService();

  _SetupStep _currentStep = _SetupStep.microphone;
  String _selectedHotkey = 'rightOption';
  final _vocabularyController = TextEditingController();

  /// Track whether we already auto-advanced for each permission step so we
  /// don't re-trigger if the user navigates back.
  final _autoAdvanced = <_SetupStep>{};

  @override
  void dispose() {
    _vocabularyController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _goToStep(_SetupStep step) {
    setState(() => _currentStep = step);
  }

  void _next() {
    final nextIndex = _currentStep.index + 1;
    if (nextIndex < _SetupStep.values.length) {
      _goToStep(_SetupStep.values[nextIndex]);
    }
  }

  Future<void> _finish() async {
    // Persist vocabulary & hotkey choices.
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.setSelectedHotkey(_selectedHotkey);
    final vocab = _vocabularyController.text.trim();
    if (vocab.isNotEmpty) {
      await notifier.setCustomVocabulary(vocab);
    }

    // Mark setup as complete.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHasCompletedSetup, true);

    // Invalidate the provider so downstream consumers see the new value.
    ref.invalidate(hasCompletedSetupProvider);

    widget.onComplete();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Watch permissions so we can auto-advance.
    final permissions = ref.watch(permissionsProvider);
    _handleAutoAdvance(permissions);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            children: [
              _buildStepIndicator(),
              const SizedBox(height: 32),
              Expanded(child: _buildCurrentStep(permissions)),
            ],
          ),
        ),
      ),
    );
  }

  /// Auto-advance permission steps when the user grants the permission in
  /// System Settings (detected by the polling provider).
  void _handleAutoAdvance(PermissionsState permissions) {
    if (_currentStep == _SetupStep.microphone &&
        permissions.microphone == PermissionStatus.granted &&
        !_autoAdvanced.contains(_SetupStep.microphone)) {
      _autoAdvanced.add(_SetupStep.microphone);
      // Schedule the navigation for after this build frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentStep == _SetupStep.microphone) {
          _next();
        }
      });
    }

    if (_currentStep == _SetupStep.accessibility &&
        permissions.accessibility == PermissionStatus.granted &&
        !_autoAdvanced.contains(_SetupStep.accessibility)) {
      _autoAdvanced.add(_SetupStep.accessibility);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentStep == _SetupStep.accessibility) {
          _next();
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Step indicator
  // ---------------------------------------------------------------------------

  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_SetupStep.totalSteps, (i) {
        final isActive = i == _currentStep.index;
        final isCompleted = i < _currentStep.index;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: isActive ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: isActive || isCompleted
                  ? CupertinoColors.activeBlue
                  : const Color(0xFFD1D1D6),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Step content
  // ---------------------------------------------------------------------------

  Widget _buildCurrentStep(PermissionsState permissions) {
    return switch (_currentStep) {
      _SetupStep.microphone => _buildMicrophoneStep(permissions),
      _SetupStep.accessibility => _buildAccessibilityStep(permissions),
      _SetupStep.hotkey => _buildHotkeyStep(),
      _SetupStep.vocabulary => _buildVocabularyStep(),
      _SetupStep.complete => _buildCompleteStep(),
    };
  }

  // -- Microphone permission --------------------------------------------------

  Widget _buildMicrophoneStep(PermissionsState permissions) {
    final isGranted = permissions.microphone == PermissionStatus.granted;

    return _StepLayout(
      stepLabel: 'Step ${_SetupStep.microphone.number} of ${_SetupStep.totalSteps}',
      icon: CupertinoIcons.mic_fill,
      iconColor: const Color(0xFFFF3B30),
      title: 'Microphone Access',
      description:
          'Wrenflow needs microphone access to record your voice for '
          'transcription. Audio is processed locally or sent to your '
          'configured transcription service — it is never stored.',
      status: isGranted ? const _PermissionBadge.granted() : null,
      action: isGranted
          ? _buildContinueButton(onPressed: _next)
          : _buildGrantButton(
              label: 'Grant Microphone Access',
              onPressed: () => _permissionService.requestMicrophone(),
            ),
    );
  }

  // -- Accessibility permission -----------------------------------------------

  Widget _buildAccessibilityStep(PermissionsState permissions) {
    final isGranted = permissions.accessibility == PermissionStatus.granted;

    return _StepLayout(
      stepLabel:
          'Step ${_SetupStep.accessibility.number} of ${_SetupStep.totalSteps}',
      icon: CupertinoIcons.hand_raised_fill,
      iconColor: const Color(0xFF5856D6),
      title: 'Accessibility Access',
      description:
          'Wrenflow uses accessibility permissions to listen for your '
          'global hotkey and to paste transcribed text into the active '
          'application.',
      status: isGranted ? const _PermissionBadge.granted() : null,
      action: isGranted
          ? _buildContinueButton(onPressed: _next)
          : _buildGrantButton(
              label: 'Open Accessibility Settings',
              onPressed: () => _permissionService.requestAccessibility(),
            ),
    );
  }

  // -- Hotkey selection -------------------------------------------------------

  Widget _buildHotkeyStep() {
    return _StepLayout(
      stepLabel: 'Step ${_SetupStep.hotkey.number} of ${_SetupStep.totalSteps}',
      icon: CupertinoIcons.keyboard,
      iconColor: const Color(0xFFFF9500),
      title: 'Choose Your Hotkey',
      description:
          'Pick a key to hold while dictating. Press and hold it to start '
          'recording, then release to transcribe and paste.',
      action: _buildContinueButton(onPressed: _next),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD1D1D6)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedHotkey,
                isExpanded: true,
                items: _hotkeyOptions.entries
                    .map((e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ))
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedHotkey = value);
                  }
                },
                style: const TextStyle(fontSize: 14, color: Colors.black87),
                icon: const Icon(CupertinoIcons.chevron_down, size: 14),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // -- Custom vocabulary (optional) -------------------------------------------

  Widget _buildVocabularyStep() {
    return _StepLayout(
      stepLabel:
          'Step ${_SetupStep.vocabulary.number} of ${_SetupStep.totalSteps}',
      icon: CupertinoIcons.textformat_abc,
      iconColor: const Color(0xFF34C759),
      title: 'Custom Vocabulary',
      description:
          'Add names, acronyms, or technical terms that the transcription '
          'engine might not recognise. One entry per line. You can always '
          'update this later in Settings.',
      action: Row(
        children: [
          Expanded(
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 14),
              onPressed: _next,
              child: const Text(
                'Skip',
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF8E8E93),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _buildContinueButton(onPressed: _next)),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          CupertinoTextField(
            controller: _vocabularyController,
            maxLines: 5,
            minLines: 3,
            placeholder: 'e.g.\nWrenflow\nRiverpod\nKubernetes',
            padding: const EdgeInsets.all(12),
            style: const TextStyle(fontSize: 13),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD1D1D6)),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // -- Complete ---------------------------------------------------------------

  Widget _buildCompleteStep() {
    return _StepLayout(
      stepLabel:
          'Step ${_SetupStep.complete.number} of ${_SetupStep.totalSteps}',
      icon: CupertinoIcons.checkmark_seal_fill,
      iconColor: const Color(0xFF34C759),
      title: 'You\'re All Set!',
      description:
          'Wrenflow is ready to go. Hold your hotkey to record, release to '
          'transcribe, and the text will be pasted into the active app.',
      action: SizedBox(
        width: double.infinity,
        child: CupertinoButton.filled(
          onPressed: _finish,
          child: const Text(
            'Start Using Wrenflow',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared button builders
  // ---------------------------------------------------------------------------

  Widget _buildContinueButton({required VoidCallback onPressed}) {
    return SizedBox(
      width: double.infinity,
      child: CupertinoButton.filled(
        onPressed: onPressed,
        child: const Text(
          'Continue',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildGrantButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: CupertinoButton.filled(
        onPressed: onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

// =============================================================================
// Helper widgets
// =============================================================================

/// Standard layout for each wizard step.
class _StepLayout extends StatelessWidget {
  const _StepLayout({
    required this.stepLabel,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    this.status,
    this.child,
    required this.action,
  });

  final String stepLabel;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final _PermissionBadge? status;
  final Widget? child;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Spacer to push content toward center.
        const Spacer(flex: 1),

        // Step label.
        Text(
          stepLabel,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Color(0xFF8E8E93),
          ),
        ),
        const SizedBox(height: 16),

        // Icon badge.
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, size: 32, color: iconColor),
        ),
        const SizedBox(height: 20),

        // Title.
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),

        // Description.
        Text(
          description,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF6E6E73),
            height: 1.4,
          ),
        ),

        // Permission status badge.
        if (status != null) ...[
          const SizedBox(height: 16),
          status!,
        ],

        // Optional extra content (dropdown, text field, etc.).
        if (child != null) child!,

        const Spacer(flex: 2),

        // Bottom action area.
        action,

        const SizedBox(height: 8),
      ],
    );
  }
}

/// Small badge that shows "Granted" with a checkmark.
class _PermissionBadge extends StatelessWidget {
  const _PermissionBadge.granted();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF34C759).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.checkmark_circle_fill,
              size: 16, color: Color(0xFF34C759)),
          SizedBox(width: 6),
          Text(
            'Granted',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF34C759),
            ),
          ),
        ],
      ),
    );
  }
}
