import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lifecycle_provider.dart';
import '../providers/audio_level_provider.dart';
import '../providers/model_state_provider.dart';
import '../providers/permissions_provider.dart';
import '../providers/pipeline_state_provider.dart';
import '../providers/settings_provider.dart';
import '../services/permission_service.dart';
import '../src/bindings/signals/signals.dart';
import '../state/app_lifecycle_state.dart';
import '../theme/wrenflow_theme.dart';
import '../widgets/green_toggle.dart';
import '../widgets/hotkey_capture.dart';
import '../widgets/initializing_dots.dart';
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
  final _permissionService = PermissionService();
  String _selectedHotkey = 'rightOption';
  final _vocabularyController = TextEditingController();
  bool _launchAtLogin = true;
  final _autoAdvanced = <OnboardingStep>{};
  final _autoRequested = <OnboardingStep>{};

  @override
  void dispose() {
    _vocabularyController.dispose();
    super.dispose();
  }

  AppLifecycleNotifier get _lifecycle =>
      ref.read(appLifecycleProvider.notifier);

  /// Whether the user can advance past the given step.
  /// Permission steps block until permission is granted.
  bool _canAdvance(OnboardingStep step, PermissionsState permissions) {
    return switch (step) {
      OnboardingStep.microphone =>
        permissions.microphone == PermissionStatus.granted,
      OnboardingStep.accessibility =>
        permissions.accessibility == PermissionStatus.granted,
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

    // Recovery mode — auto-returns via provider, just show permission steps.
    if (widget.mode == WizardMode.recovery && lifecycle is PermissionRecovery) {
      return _buildRecoveryScreen(permissions, lifecycle.missing);
    }

    // Onboarding mode — driven by lifecycle state.
    final currentStep = lifecycle is Onboarding
        ? lifecycle.currentStep
        : OnboardingStep.microphone;

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
              child: _buildStep(currentStep, permissions,
                  key: ValueKey(currentStep)),
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
        permissions.microphone == PermissionStatus.unknown &&
        !_autoRequested.contains(OnboardingStep.microphone)) {
      _autoRequested.add(OnboardingStep.microphone);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        debugPrint('[wizard] auto-requesting microphone permission');
        await _permissionService.requestMicrophone();
      });
    }

    // Auto-advance when permission is granted.
    if (step == OnboardingStep.microphone &&
        permissions.microphone == PermissionStatus.granted &&
        !_autoAdvanced.contains(OnboardingStep.microphone)) {
      _autoAdvanced.add(OnboardingStep.microphone);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _lifecycle.onboardingNext();
      });
    }

    if (step == OnboardingStep.accessibility &&
        permissions.accessibility == PermissionStatus.granted &&
        !_autoAdvanced.contains(OnboardingStep.accessibility)) {
      _autoAdvanced.add(OnboardingStep.accessibility);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _lifecycle.onboardingNext();
      });
    }
  }

  // ── Recovery screen ───────────────────────────────────────

  Widget _buildRecoveryScreen(
      PermissionsState permissions, MissingPermissions missing) {
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
                      permissions.microphone == PermissionStatus.granted,
                      () async {
                        final granted =
                            await _permissionService.requestMicrophone();
                        if (!granted && mounted) {
                          await _permissionService.openMicrophoneSettings();
                        }
                      },
                    ),
                  if (missing.accessibility)
                    _permissionRow(
                      'Accessibility',
                      permissions.accessibility == PermissionStatus.granted,
                      () async {
                        final granted =
                            await _permissionService.requestAccessibility();
                        if (!granted && mounted) {
                          await _permissionService.openAccessibilitySettings();
                        }
                      },
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
                Icon(CupertinoIcons.checkmark_circle_fill,
                    size: 13, color: WrenflowStyle.green),
                const SizedBox(width: 6),
                Text('$name — Granted',
                    style: WrenflowStyle.body(12)
                        .copyWith(color: WrenflowStyle.green)),
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
                style: WrenflowStyle.body(12)
                    .copyWith(color: WrenflowStyle.textTertiary),
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
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
        );
      }),
    );
  }

  // ── Step content ──────────────────────────────────────────

  Widget _buildStep(OnboardingStep step, PermissionsState permissions,
      {Key? key}) {
    return switch (step) {
      OnboardingStep.microphone => _buildPermissionStep(
          key: key,
          icon: CupertinoIcons.mic_fill,
          title: 'Microphone',
          subtitle: 'Wrenflow needs microphone access to record your voice.',
          isGranted: permissions.microphone == PermissionStatus.granted,
          onGrant: () async {
            final granted = await _permissionService.requestMicrophone();
            if (!granted && mounted) {
              await _permissionService.openMicrophoneSettings();
            }
          },
        ),
      OnboardingStep.accessibility => _buildPermissionStep(
          key: key,
          icon: CupertinoIcons.hand_raised_fill,
          title: 'Accessibility',
          subtitle: 'Required for global hotkey and pasting text.',
          isGranted: permissions.accessibility == PermissionStatus.granted,
          onGrant: () async {
            final granted = await _permissionService.requestAccessibility();
            if (!granted && mounted) {
              await _permissionService.openAccessibilitySettings();
            }
          },
        ),
      OnboardingStep.hotkey => _buildHotkeyStep(key: key),
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
        Icon(CupertinoIcons.checkmark_circle_fill,
            size: 13, color: WrenflowStyle.green),
        const SizedBox(width: 4),
        Text('Granted',
            style:
                WrenflowStyle.body(12).copyWith(color: WrenflowStyle.green)),
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
        onKeySelected: (value) => setState(() => _selectedHotkey = value),
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
      subtitle:
          'Try it out — hold your hotkey to record, release to transcribe.',
      child: Column(
        children: [
          // Live pipeline state + transcription result
          const _TranscriptionTestWidget(),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Launch at login', style: WrenflowStyle.body(12)),
              GreenToggle(
                value: _launchAtLogin,
                onChanged: (v) => setState(() => _launchAtLogin = v),
              ),
            ],
          ),
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
    final modelState = ref.watch(modelStateProvider).value;

    // Hide when ready — no need to show anything.
    if (modelState == null || modelState is ModelStateReady) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: _buildContent(modelState),
    );
  }

  Widget _buildContent(ModelState state) {
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
          Text('Downloading model — $pct%',
              style: WrenflowStyle.mono(9).copyWith(
                  color: WrenflowStyle.textTertiary)),
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
          Text('Loading model...',
              style: WrenflowStyle.mono(9).copyWith(
                  color: WrenflowStyle.textTertiary)),
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
          Text('Warming up model...',
              style: WrenflowStyle.mono(9).copyWith(
                  color: WrenflowStyle.textTertiary)),
        ],
      );
    }

    if (state is ModelStateError) {
      return Text('Model: ${state.message}',
          style: WrenflowStyle.mono(9).copyWith(color: WrenflowStyle.red),
          maxLines: 1,
          overflow: TextOverflow.ellipsis);
    }

    // NotDownloaded or unknown
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
        Text('Preparing model...',
            style: WrenflowStyle.mono(9).copyWith(
                color: WrenflowStyle.textTertiary)),
      ],
    );
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
  String? _lastTranscript;

  @override
  void initState() {
    super.initState();
    _waveformController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // Listen for transcription results.
    TranscriptReady.rustSignalStream.listen((signal) {
      if (mounted) {
        setState(() {
          _lastTranscript = signal.message.transcript;
        });
      }
    });
  }

  @override
  void dispose() {
    _waveformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pipelineAsync = ref.watch(pipelineStateProvider);
    final pipeline = pipelineAsync.value;

    // Clear old transcript when a new recording starts.
    if (pipeline is PipelineStateStarting || pipeline is PipelineStateRecording) {
      _lastTranscript = null;
    }

    return Container(
      width: double.infinity,
      height: 48,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: WrenflowStyle.textOp05,
        borderRadius: BorderRadius.circular(7),
      ),
      child: _buildContent(pipeline),
    );
  }

  Widget _buildContent(PipelineState? pipeline) {
    // Check model state first — can't test without a loaded model.
    final modelState = ref.watch(modelStateProvider).value;
    if (modelState is ModelStateDownloading) {
      final pct = (modelState.progress * 100).toInt();
      return Column(
        key: const ValueKey('model-downloading'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: modelState.progress,
              minHeight: 4,
              backgroundColor: WrenflowStyle.textOp10,
              valueColor: AlwaysStoppedAnimation(WrenflowStyle.textOp50),
            ),
          ),
          const SizedBox(height: 4),
          Text('Downloading model — $pct%',
              style: WrenflowStyle.caption(10)),
        ],
      );
    }
    if (modelState is ModelStateLoading) {
      return Center(
        key: const ValueKey('model-loading'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text('Loading model...', style: WrenflowStyle.caption(11)),
          ],
        ),
      );
    }
    if (modelState is ModelStateWarming) {
      return Center(
        key: const ValueKey('model-warming'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text('Warming up model...', style: WrenflowStyle.caption(11)),
          ],
        ),
      );
    }
    if (modelState is ModelStateError) {
      return Center(
        key: const ValueKey('model-error'),
        child: GestureDetector(
          onTap: () => const InitializeLocalModel().sendSignalToRust(),
          child: Text('Model error. Tap to retry.',
              style: WrenflowStyle.caption(11)
                  .copyWith(color: WrenflowStyle.red)),
        ),
      );
    }
    if (modelState is! ModelStateReady) {
      return Center(
        key: const ValueKey('model-init'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text('Preparing model...', style: WrenflowStyle.caption(11)),
          ],
        ),
      );
    }

    if (_lastTranscript != null) {
      return Center(
        key: const ValueKey('result'),
        child: SingleChildScrollView(
          child: Text(
            _lastTranscript!,
            style: WrenflowStyle.body(12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (pipeline is PipelineStateRecording) {
      final audioLevel = ref.watch(audioLevelProvider).value ?? 0.0;
      return Center(
        key: const ValueKey('recording'),
        child: AnimatedBuilder(
          animation: _waveformController,
          builder: (context, _) {
            return CustomPaint(
              size: const Size(200, 20),
              painter: WaveformPainter(
                audioLevel: audioLevel,
                animationValue: _waveformController.value,
              ),
            );
          },
        ),
      );
    }

    if (pipeline is PipelineStateStarting ||
        pipeline is PipelineStateInitializing) {
      return Center(
        key: const ValueKey('starting'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text('Starting...', style: WrenflowStyle.caption(11)),
          ],
        ),
      );
    }

    if (pipeline is PipelineStateTranscribing) {
      return Center(
        key: const ValueKey('transcribing'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InitializingDots(),
            const SizedBox(width: 8),
            Text('Transcribing...', style: WrenflowStyle.caption(11)),
          ],
        ),
      );
    }

    if (pipeline is PipelineStateError) {
      return Center(
        key: const ValueKey('error'),
        child: Text(
          pipeline.message,
          style: WrenflowStyle.caption(11).copyWith(color: WrenflowStyle.red),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return Center(
      key: const ValueKey('idle'),
      child: Text(
        'Press and hold your hotkey now to test.',
        style: WrenflowStyle.caption(11),
        textAlign: TextAlign.center,
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
          Text(subtitle,
              textAlign: TextAlign.center,
              style: WrenflowStyle.caption(12)),
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
