import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/permissions_provider.dart';
import '../providers/settings_provider.dart';
import '../services/permission_service.dart';
import '../theme/wrenflow_theme.dart';
import '../widgets/green_toggle.dart';

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

  int get number => index + 1;
  static int get totalSteps => values.length;
}

/// Multi-step onboarding wizard — pixel-perfect port of Swift WrenflowStyle.
class SetupWizardScreen extends ConsumerStatefulWidget {
  const SetupWizardScreen({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen> {
  final _permissionService = PermissionService();

  _SetupStep _currentStep = _SetupStep.microphone;
  String _selectedHotkey = 'rightOption';
  final _vocabularyController = TextEditingController();
  bool _launchAtLogin = true;
  final _autoAdvanced = <_SetupStep>{};

  @override
  void dispose() {
    _vocabularyController.dispose();
    super.dispose();
  }

  void _goToStep(_SetupStep step) => setState(() => _currentStep = step);

  void _next() {
    final nextIndex = _currentStep.index + 1;
    if (nextIndex < _SetupStep.values.length) {
      _goToStep(_SetupStep.values[nextIndex]);
    }
  }

  void _back() {
    if (_currentStep.index > 0) {
      _goToStep(_SetupStep.values[_currentStep.index - 1]);
    }
  }

  Future<void> _finish() async {
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.setSelectedHotkey(_selectedHotkey);
    final vocab = _vocabularyController.text.trim();
    if (vocab.isNotEmpty) {
      await notifier.setCustomVocabulary(vocab);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHasCompletedSetup, true);
    ref.invalidate(hasCompletedSetupProvider);
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(permissionsProvider);
    _handleAutoAdvance(permissions);

    return Scaffold(
      backgroundColor: WrenflowStyle.surface,
      body: Column(
        children: [
          // Inset for macOS traffic lights.
          const SizedBox(height: 28),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeInOut,
              switchOutCurve: Curves.easeInOut,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.05, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _buildCurrentStep(
                permissions,
                key: ValueKey(_currentStep),
              ),
            ),
          ),
          _buildFooter(),
        ],
      ),
    );
  }

  void _handleAutoAdvance(PermissionsState permissions) {
    if (_currentStep == _SetupStep.microphone &&
        permissions.microphone == PermissionStatus.granted &&
        !_autoAdvanced.contains(_SetupStep.microphone)) {
      _autoAdvanced.add(_SetupStep.microphone);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentStep == _SetupStep.microphone) _next();
      });
    }

    if (_currentStep == _SetupStep.accessibility &&
        permissions.accessibility == PermissionStatus.granted &&
        !_autoAdvanced.contains(_SetupStep.accessibility)) {
      _autoAdvanced.add(_SetupStep.accessibility);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentStep == _SetupStep.accessibility) _next();
      });
    }
  }

  // ── Footer ──────────────────────────────────────────────────

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          // Back button
          if (_currentStep.index > 0)
            GestureDetector(
              onTap: _back,
              child: Text('Back', style: WrenflowStyle.body(12).copyWith(
                color: WrenflowStyle.textTertiary,
              )),
            )
          else
            const SizedBox(width: 32),

          const Spacer(),

          // Step dots
          _buildStepDots(),

          const Spacer(),

          // Action button
          _buildFooterAction(),
        ],
      ),
    );
  }

  Widget _buildStepDots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_SetupStep.totalSteps, (i) {
        final isCurrent = i == _currentStep.index;
        final isCompleted = i < _currentStep.index;
        final double size = isCurrent ? 6 : 5;
        final Color color = isCurrent
            ? WrenflowStyle.textOp50
            : isCompleted
                ? WrenflowStyle.greenOp50
                : WrenflowStyle.textOp10;

        return Padding(
          padding: EdgeInsets.only(left: i > 0 ? 5 : 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildFooterAction() {
    if (_currentStep == _SetupStep.complete) {
      return _FooterButton(
        label: 'Finish',
        onTap: _finish,
      );
    }
    return _FooterButton(
      label: 'Next',
      onTap: _next,
    );
  }

  // ── Step content ────────────────────────────────────────────

  Widget _buildCurrentStep(PermissionsState permissions, {Key? key}) {
    return switch (_currentStep) {
      _SetupStep.microphone => _buildPermissionStep(
        key: key,
        icon: CupertinoIcons.mic_fill,
        title: 'Microphone',
        subtitle: 'Wrenflow needs microphone access to record your voice.',
        isGranted: permissions.microphone == PermissionStatus.granted,
        onGrant: () => _permissionService.requestMicrophone(),
      ),
      _SetupStep.accessibility => _buildPermissionStep(
        key: key,
        icon: CupertinoIcons.hand_raised_fill,
        title: 'Accessibility',
        subtitle: 'Required for global hotkey and pasting text.',
        isGranted: permissions.accessibility == PermissionStatus.granted,
        onGrant: () => _permissionService.requestAccessibility(),
      ),
      _SetupStep.hotkey => _buildHotkeyStep(key: key),
      _SetupStep.vocabulary => _buildVocabularyStep(key: key),
      _SetupStep.complete => _buildCompleteStep(key: key),
    };
  }

  Widget _buildPermissionStep({
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isGranted,
    required VoidCallback onGrant,
  }) {
    return _StepContent(
      key: key,
      icon: icon,
      title: title,
      subtitle: subtitle,
      child: isGranted
          ? _grantedBadge()
          : _grantButton(onTap: onGrant),
    );
  }

  Widget _grantedBadge() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.checkmark_circle_fill, size: 13, color: WrenflowStyle.green),
        const SizedBox(width: 4),
        Text('Granted', style: WrenflowStyle.body(12).copyWith(color: WrenflowStyle.green)),
      ],
    );
  }

  Widget _grantButton({required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: WrenflowStyle.permissionButtonDecoration,
        child: Center(
          child: Text('Grant Access', style: WrenflowStyle.body(12)),
        ),
      ),
    );
  }

  Widget _buildHotkeyStep({Key? key}) {
    return _StepContent(
      key: key,
      icon: CupertinoIcons.keyboard,
      title: 'Hotkey',
      subtitle: 'Hold to record, release to transcribe and paste.',
      child: Column(
        children: _hotkeyOptions.entries.map((entry) {
          final isSelected = _selectedHotkey == entry.key;
          return GestureDetector(
            onTap: () => setState(() => _selectedHotkey = entry.key),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: isSelected ? WrenflowStyle.textOp05 : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                    size: 13,
                    color: isSelected
                        ? WrenflowStyle.text
                        : WrenflowStyle.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Text(entry.value, style: WrenflowStyle.body(12)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildVocabularyStep({Key? key}) {
    return _StepContent(
      key: key,
      icon: CupertinoIcons.textformat_abc,
      title: 'Vocabulary',
      subtitle: 'Add names or terms to improve recognition.',
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: WrenflowStyle.bg,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: WrenflowStyle.border, width: 1),
        ),
        child: TextField(
          controller: _vocabularyController,
          maxLines: null,
          expands: true,
          style: WrenflowStyle.mono(11),
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(8),
            hintText: 'One per line...',
            hintStyle: TextStyle(
              fontFamily: 'Menlo',
              fontSize: 11,
              color: Color.fromRGBO(153, 153, 153, 1.0),
            ),
            isDense: true,
          ),
        ),
      ),
    );
  }

  Widget _buildCompleteStep({Key? key}) {
    return _StepContent(
      key: key,
      icon: CupertinoIcons.checkmark_seal_fill,
      title: 'Ready',
      subtitle: 'Hold your hotkey to record, release to transcribe.',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Launch at login', style: WrenflowStyle.body(12)),
          GreenToggle(
            value: _launchAtLogin,
            onChanged: (v) => setState(() => _launchAtLogin = v),
          ),
        ],
      ),
    );
  }
}

// ── Shared step layout ────────────────────────────────────────

class _StepContent extends StatelessWidget {
  const _StepContent({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),

          // Icon circle
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: WrenflowStyle.textOp05,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 17, color: WrenflowStyle.textOp70),
          ),
          const SizedBox(height: 10),

          // Title
          Text(title, style: WrenflowStyle.title(16)),
          const SizedBox(height: 4),

          // Subtitle
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: WrenflowStyle.caption(12),
          ),
          const SizedBox(height: 14),

          // Content
          child,

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// ── Footer button ─────────────────────────────────────────────

class _FooterButton extends StatelessWidget {
  const _FooterButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: WrenflowStyle.footerButtonDecoration,
        child: Text(label, style: WrenflowStyle.body(12)),
      ),
    );
  }
}
