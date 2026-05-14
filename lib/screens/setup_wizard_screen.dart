import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lifecycle_provider.dart';
import '../providers/launch_at_login_provider.dart';
import '../providers/local_models_provider.dart';
import '../providers/model_state_provider.dart';
import '../providers/permissions_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/transcription_test_presentation_provider.dart';
import '../shell/shell_capabilities.dart';
import '../src/bindings/signals/signals.dart';
import '../state/app_lifecycle_state.dart';
import '../theme/wrenflow_theme.dart';
import '../widgets/green_toggle.dart';
import '../widgets/hotkey_capture.dart';
import '../widgets/initializing_dots.dart';
import '../widgets/local_model_picker.dart';
import '../widgets/model_download_widget.dart';
import '../widgets/waveform_painter.dart';

/// Setup wizard — used for both onboarding and permission recovery.
///
/// In onboarding mode: all 5 steps (microphone, accessibility, hotkey, vocabulary, complete).
/// In recovery mode: only missing permission steps, auto-returns to Running when granted.
class SetupWizardScreen extends ConsumerStatefulWidget {
  const SetupWizardScreen({super.key, required this.mode});

  final WizardMode mode;

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen> {
  String _selectedHotkey = '61';
  final _vocabularyController = TextEditingController();
  final _autoRequested = <OnboardingStep>{};
  String? _lastSyncedHotkey;
  String? _lastSyncedVocabulary;

  @override
  void dispose() {
    _vocabularyController.dispose();
    super.dispose();
  }

  AppLifecycleNotifier get _lifecycle =>
      ref.read(appLifecycleProvider.notifier);

  PermissionsNotifier get _permissions =>
      ref.read(permissionsProvider.notifier);

  void _hydrateSettings(AppSettings settings) {
    final hotkeyWasEdited =
        _lastSyncedHotkey != null && _selectedHotkey != _lastSyncedHotkey;
    if (!hotkeyWasEdited) {
      _selectedHotkey = settings.selectedHotkey;
      _lastSyncedHotkey = settings.selectedHotkey;
    }

    final vocabularyWasEdited =
        _lastSyncedVocabulary != null &&
        _vocabularyController.text != _lastSyncedVocabulary;
    if (!vocabularyWasEdited) {
      final text = settings.customVocabulary;
      _vocabularyController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _lastSyncedVocabulary = text;
    }
  }

  /// Whether the user can advance past the given step.
  /// Permission steps block until permission is granted.
  bool _canAdvance(OnboardingStep step, PermissionsState permissions) {
    return switch (step) {
      OnboardingStep.microphone =>
        permissions.microphone == PermissionUiStatus.granted,
      OnboardingStep.accessibility =>
        permissions.accessibility == PermissionUiStatus.granted,
      _ => true,
    };
  }

  Future<void> _finish() async {
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.setSelectedHotkey(_selectedHotkey);
    final vocab = _vocabularyController.text.trim();
    if (vocab.isNotEmpty) {
      await notifier.setCustomVocabulary(vocab);
    }
    await _lifecycle.completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final lifecycle = ref.watch(appLifecycleProvider);
    final permissions = ref.watch(permissionsProvider);
    final settings = ref.watch(settingsProvider);

    // Recovery mode — auto-returns via provider, just show permission steps.
    if (widget.mode == WizardMode.recovery && lifecycle is PermissionRecovery) {
      return _buildRecoveryScreen(permissions, lifecycle.missing);
    }

    // Onboarding mode — driven by lifecycle state.
    final currentStep = lifecycle is Onboarding
        ? lifecycle.currentStep
        : OnboardingStep.microphone;

    _hydrateSettings(settings);
    _handleAutoAdvance(permissions, currentStep);
    _syncSettingsIfNeeded(currentStep);

    return Scaffold(
      backgroundColor: WrenflowStyle.surface,
      body: Column(
        children: [
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
              child: _buildStep(
                currentStep,
                permissions,
                key: ValueKey(currentStep),
              ),
            ),
          ),
          if (currentStep != OnboardingStep.complete)
            const _GlobalModelIndicator(),
          _buildFooter(currentStep),
        ],
      ),
    );
  }

  // ── Sync settings to Rust when reaching complete step ──────

  bool _settingsSynced = false;

  void _syncSettingsIfNeeded(OnboardingStep step) {
    // Sync settings when reaching complete step.
    if (step == OnboardingStep.complete && !_settingsSynced) {
      _settingsSynced = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final notifier = ref.read(settingsProvider.notifier);
        await notifier.setSelectedHotkey(_selectedHotkey);
        final vocab = _vocabularyController.text.trim();
        if (vocab.isNotEmpty) {
          await notifier.setCustomVocabulary(vocab);
        }
      });
    }
    if (step != OnboardingStep.complete) {
      _settingsSynced = false;
    }
  }

  // ── Auto-advance permission steps ─────────────────────────

  void _handleAutoAdvance(PermissionsState permissions, OnboardingStep step) {
    // Auto-request microphone permission when the step first appears.
    // Only triggers the system dialog — does NOT open Settings on denial.
    if (step == OnboardingStep.microphone &&
        permissions.microphone == PermissionUiStatus.unknown &&
        !_autoRequested.contains(OnboardingStep.microphone)) {
      _autoRequested.add(OnboardingStep.microphone);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        debugPrint('[wizard] auto-requesting microphone permission');
        await _permissions.requestMicrophone();
      });
    }
  }

  // ── Recovery screen ───────────────────────────────────────

  Widget _buildRecoveryScreen(
    PermissionsState permissions,
    MissingPermissions missing,
  ) {
    return Scaffold(
      backgroundColor: WrenflowStyle.surface,
      body: Column(
        children: [
          const SizedBox(height: 28),
          Expanded(
            child: _StepContent(
              icon: CupertinoIcons.exclamationmark_triangle_fill,
              title: 'Permissions Required',
              subtitle: 'Some permissions were revoked. Please re-grant them.',
              child: Column(
                children: [
                  if (missing.microphone)
                    _permissionRow(
                      'Microphone',
                      permissions.microphone == PermissionUiStatus.granted,
                      () => _permissions.requestMicrophone(
                        openSettingsOnDeny: true,
                      ),
                    ),
                  if (missing.accessibility)
                    _permissionRow(
                      'Accessibility',
                      permissions.accessibility == PermissionUiStatus.granted,
                      () => _permissions.requestAccessibility(
                        openSettingsOnDeny: true,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionRow(String name, bool granted, VoidCallback onGrant) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: granted
          ? Row(
              children: [
                Icon(
                  CupertinoIcons.checkmark_circle_fill,
                  size: 13,
                  color: WrenflowStyle.green,
                ),
                const SizedBox(width: 6),
                Text(
                  '$name — Granted',
                  style: WrenflowStyle.body(
                    12,
                  ).copyWith(color: WrenflowStyle.green),
                ),
              ],
            )
          : GestureDetector(
              onTap: onGrant,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: WrenflowStyle.permissionButtonDecoration,
                child: Center(
                  child: Text('Grant $name', style: WrenflowStyle.body(12)),
                ),
              ),
            ),
    );
  }

  // ── Onboarding footer ─────────────────────────────────────

  Widget _buildFooter(OnboardingStep step) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (step.index > 0)
            GestureDetector(
              onTap: () => _lifecycle.onboardingBack(),
              child: Text(
                'Back',
                style: WrenflowStyle.body(
                  12,
                ).copyWith(color: WrenflowStyle.textTertiary),
              ),
            )
          else
            const SizedBox(width: 32),
          const Spacer(),
          _buildStepDots(step),
          const Spacer(),
          step == OnboardingStep.complete
              ? _FooterButton(label: 'Finish', onTap: _finish)
              : _FooterButton(
                  label: 'Next',
                  onTap: _canAdvance(step, ref.read(permissionsProvider))
                      ? () => _lifecycle.onboardingNext()
                      : null,
                ),
        ],
      ),
    );
  }

  Widget _buildStepDots(OnboardingStep step) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(OnboardingStep.values.length, (i) {
        final isCurrent = i == step.index;
        final isCompleted = i < step.index;
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
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        );
      }),
    );
  }

  // ── Step content ──────────────────────────────────────────

  Widget _buildStep(
    OnboardingStep step,
    PermissionsState permissions, {
    Key? key,
  }) {
    return switch (step) {
      OnboardingStep.microphone => _buildPermissionStep(
        key: key,
        icon: CupertinoIcons.mic_fill,
        title: 'Microphone',
        subtitle: 'Wrenflow needs microphone access to record your voice.',
        isGranted: permissions.microphone == PermissionUiStatus.granted,
        onGrant: () =>
            _permissions.requestMicrophone(openSettingsOnDeny: true),
      ),
      OnboardingStep.accessibility => _buildPermissionStep(
        key: key,
        icon: CupertinoIcons.hand_raised_fill,
        title: 'Accessibility',
        subtitle: 'Required for global hotkey and pasting text.',
        isGranted: permissions.accessibility == PermissionUiStatus.granted,
        onGrant: () =>
            _permissions.requestAccessibility(openSettingsOnDeny: true),
      ),
      OnboardingStep.hotkey => _buildHotkeyStep(key: key),
      OnboardingStep.model => _buildModelStep(key: key),
      OnboardingStep.vocabulary => _buildVocabularyStep(key: key),
      OnboardingStep.complete => _buildCompleteStep(key: key),
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
      child: isGranted ? _grantedBadge() : _grantButton(onTap: onGrant),
    );
  }

  Widget _grantedBadge() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          CupertinoIcons.checkmark_circle_fill,
          size: 13,
          color: WrenflowStyle.green,
        ),
        const SizedBox(width: 4),
        Text(
          'Granted',
          style: WrenflowStyle.body(12).copyWith(color: WrenflowStyle.green),
        ),
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
      child: HotkeyCapture(
        currentValue: _selectedHotkey,
        onKeySelected: (value) => setState(() {
          _selectedHotkey = value;
          _lastSyncedHotkey = value;
        }),
      ),
    );
  }

  Widget _buildModelStep({Key? key}) {
    return _StepContent(
      key: key,
      icon: CupertinoIcons.waveform_path_ecg,
      title: 'Transcription Model',
      subtitle:
          'Choose your preferred local model first. Nothing downloads or activates until you do it explicitly.',
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LocalModelPicker(compact: true),
          SizedBox(height: 12),
          ModelDownloadWidget(),
        ],
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
    final launchAtLogin = ref.watch(launchAtLoginProvider);
    final shellCapabilities = ref.watch(shellCapabilitiesProvider);
    return _StepContent(
      key: key,
      icon: CupertinoIcons.checkmark_seal_fill,
      title: 'Ready',
      subtitle:
          'Try it out — hold your hotkey to record, release to transcribe.',
      child: Column(
        children: [
          // Live pipeline state + transcription result
          const _TranscriptionTestWidget(),
          if (shellCapabilities.launchAtLogin) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Launch at login', style: WrenflowStyle.body(12)),
                Opacity(
                  opacity: launchAtLogin.isLoading ? 0.55 : 1,
                  child: IgnorePointer(
                    ignoring: launchAtLogin.isLoading,
                    child: GreenToggle(
                      value: launchAtLogin.enabled,
                      onChanged: (v) => ref
                          .read(launchAtLoginProvider.notifier)
                          .setEnabled(v),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Global model indicator (visible on all wizard steps) ───────

class _GlobalModelIndicator extends ConsumerWidget {
  const _GlobalModelIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelOperation = ref.watch(globalModelOperationProvider);
    final modelState = modelOperation?.state;
    final models = ref.watch(localModelsProvider);
    final selectedModel = ref.watch(selectedLocalModelProvider);
    final operationModelId = modelOperation?.modelId;
    final operationModel = operationModelId == null
        ? null
        : models.where((model) => model.id == operationModelId).isEmpty
        ? null
        : models.firstWhere((model) => model.id == operationModelId);

    if (modelState == null ||
        modelState is ModelStateNotDownloaded ||
        modelState is ModelStateReady) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: _buildContent(
        modelState,
        operationModel?.displayName ??
            selectedModel?.displayName ??
            'selected model',
      ),
    );
  }

  Widget _buildContent(ModelState state, String modelName) {
    if (state is ModelStateDownloading) {
      final pct = (state.progress * 100).toInt();
      return Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: state.progress,
              minHeight: 3,
              backgroundColor: WrenflowStyle.textOp10,
              valueColor: AlwaysStoppedAnimation(WrenflowStyle.textOp50),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Downloading $modelName — $pct%',
            style: WrenflowStyle.mono(
              9,
            ).copyWith(color: WrenflowStyle.textTertiary),
          ),
        ],
      );
    }

    if (state is ModelStateLoading) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(WrenflowStyle.textTertiary),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Loading $modelName...',
            style: WrenflowStyle.mono(
              9,
            ).copyWith(color: WrenflowStyle.textTertiary),
          ),
        ],
      );
    }

    if (state is ModelStateWarming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(WrenflowStyle.textTertiary),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Warming up $modelName...',
            style: WrenflowStyle.mono(
              9,
            ).copyWith(color: WrenflowStyle.textTertiary),
          ),
        ],
      );
    }

    if (state is ModelStateError) {
      return Text(
        'Model: ${state.message}',
        style: WrenflowStyle.mono(9).copyWith(color: WrenflowStyle.red),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return const SizedBox.shrink();
  }
}

// ── Transcription test widget (for complete step) ─────────────

class _TranscriptionTestWidget extends ConsumerStatefulWidget {
  const _TranscriptionTestWidget();

  @override
  ConsumerState<_TranscriptionTestWidget> createState() =>
      _TranscriptionTestWidgetState();
}

class _TranscriptionTestWidgetState
    extends ConsumerState<_TranscriptionTestWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveformController;

  @override
  void initState() {
    super.initState();
    _waveformController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _waveformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presentation = ref.watch(transcriptionTestPresentationProvider);

    return Container(
      width: double.infinity,
      height: 48,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: WrenflowStyle.textOp05,
        borderRadius: BorderRadius.circular(7),
      ),
      child: _buildContent(presentation),
    );
  }

  Widget _buildContent(TranscriptionTestPresentation presentation) {
    switch (presentation.phase) {
      case TranscriptionTestPhase.loadingCatalog:
      return Center(
        key: const ValueKey('model-catalog-loading'),
        child: Text(
          presentation.message!,
          style: WrenflowStyle.caption(11),
          textAlign: TextAlign.center,
        ),
      );
      case TranscriptionTestPhase.modelDownloading:
      final pct = ((presentation.progress ?? 0) * 100).toInt();
      return Column(
        key: const ValueKey('model-downloading'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: presentation.progress ?? 0,
              minHeight: 4,
              backgroundColor: WrenflowStyle.textOp10,
              valueColor: AlwaysStoppedAnimation(WrenflowStyle.textOp50),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${presentation.message} — $pct%',
            style: WrenflowStyle.caption(10),
          ),
        ],
      );
      case TranscriptionTestPhase.modelLoading:
      return Center(
        key: const ValueKey('model-loading'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text(presentation.message!, style: WrenflowStyle.caption(11)),
          ],
        ),
      );
      case TranscriptionTestPhase.modelWarming:
      return Center(
        key: const ValueKey('model-warming'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text(presentation.message!, style: WrenflowStyle.caption(11)),
          ],
        ),
      );
      case TranscriptionTestPhase.modelError:
      return Center(
        key: const ValueKey('model-error'),
        child: GestureDetector(
          onTap: () => const InitializeLocalModel().sendSignalToRust(),
          child: Text(
            presentation.message!,
            style: WrenflowStyle.caption(11).copyWith(color: WrenflowStyle.red),
          ),
        ),
      );
      case TranscriptionTestPhase.modelManual:
      return Center(
        key: const ValueKey('model-manual'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              presentation.message!,
              style: WrenflowStyle.caption(11),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => const InitializeLocalModel().sendSignalToRust(),
              child: Text(
                'Activate selected model',
                style: WrenflowStyle.body(
                  11,
                ).copyWith(color: WrenflowStyle.textOp50),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
      case TranscriptionTestPhase.modelPending:
      return Center(
        key: const ValueKey('model-pending'),
        child: Text(
          presentation.message!,
          style: WrenflowStyle.caption(11),
          textAlign: TextAlign.center,
        ),
      );
      case TranscriptionTestPhase.transcript:
      return Center(
        key: const ValueKey('result'),
        child: SingleChildScrollView(
          child: Text(
            presentation.message!,
            style: WrenflowStyle.body(12),
            textAlign: TextAlign.center,
          ),
        ),
      );
      case TranscriptionTestPhase.recording:
      return Center(
        key: const ValueKey('recording'),
        child: AnimatedBuilder(
          animation: _waveformController,
          builder: (context, _) {
            return CustomPaint(
              size: const Size(200, 20),
              painter: WaveformPainter(
                audioLevel: presentation.audioLevel ?? 0.0,
                animationValue: _waveformController.value,
              ),
            );
          },
        ),
      );
      case TranscriptionTestPhase.starting:
      return Center(
        key: const ValueKey('starting'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text(presentation.message!, style: WrenflowStyle.caption(11)),
          ],
        ),
      );
      case TranscriptionTestPhase.transcribing:
      return Center(
        key: const ValueKey('transcribing'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text(presentation.message!, style: WrenflowStyle.caption(11)),
          ],
        ),
      );
      case TranscriptionTestPhase.pipelineError:
      return Center(
        key: const ValueKey('error'),
        child: Text(
          presentation.message!,
          style: WrenflowStyle.caption(11).copyWith(color: WrenflowStyle.red),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
      case TranscriptionTestPhase.idle:
      return Center(
        key: const ValueKey('idle'),
        child: Text(
          presentation.message!,
          style: WrenflowStyle.caption(11),
          textAlign: TextAlign.center,
        ),
      );
    }
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
          Text(title, style: WrenflowStyle.title(16)),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: WrenflowStyle.caption(12),
          ),
          const SizedBox(height: 14),
          child,
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  const _FooterButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: disabled ? 0.3 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: WrenflowStyle.footerButtonDecoration,
          child: Text(label, style: WrenflowStyle.body(12)),
        ),
      ),
    );
  }
}
