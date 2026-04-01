import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wrenflow/providers/audio_level_provider.dart';
import 'package:wrenflow/providers/pipeline_state_provider.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';
import 'package:wrenflow/theme/wrenflow_theme.dart';
import 'package:wrenflow/widgets/initializing_dots.dart';
import 'package:wrenflow/widgets/waveform_painter.dart';

/// Floating overlay that shows recording status.
///
/// Light theme, compact: 120pt wide, 32pt tall, corner 12.
/// States: initializing = 3-dot anim, recording = waveform only,
/// transcribing = 3-dot anim, done = fade out.
class RecordingOverlay extends ConsumerWidget {
  const RecordingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pipelineAsync = ref.watch(pipelineStateProvider);
    final state = pipelineAsync.value;

    if (state == null ||
        state is PipelineStateIdle ||
        state is PipelineStateError) {
      return const SizedBox.shrink();
    }

    return _AnimatedOverlayContainer(state: state);
  }
}

class _AnimatedOverlayContainer extends ConsumerStatefulWidget {
  const _AnimatedOverlayContainer({required this.state});

  final PipelineState state;

  @override
  ConsumerState<_AnimatedOverlayContainer> createState() =>
      _AnimatedOverlayContainerState();
}

class _AnimatedOverlayContainerState
    extends ConsumerState<_AnimatedOverlayContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDone = widget.state is PipelineStatePasting;

    return Center(
      child: AnimatedOpacity(
        opacity: isDone ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: Container(
          width: 120,
          height: 32,
          decoration: BoxDecoration(
            color: WrenflowStyle.bg,
            borderRadius: BorderRadius.circular(WrenflowStyle.radiusLarge),
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _buildPhaseContent(widget.state),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhaseContent(PipelineState state) {
    return switch (state) {
      PipelineStateStarting() || PipelineStateInitializing() =>
        const InitializingDots(key: ValueKey('loading')),
      PipelineStateRecording() => _RecordingContent(
        key: const ValueKey('recording'),
        controller: _controller,
        ref: ref,
      ),
      PipelineStateTranscribing() =>
        const InitializingDots(key: ValueKey('transcribing')),
      PipelineStatePasting() =>
        const SizedBox.shrink(key: ValueKey('done')),
      _ => const SizedBox.shrink(),
    };
  }
}

class _RecordingContent extends StatelessWidget {
  const _RecordingContent({
    super.key,
    required this.controller,
    required this.ref,
  });

  final AnimationController controller;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final audioAsync = ref.watch(audioLevelProvider);
    final audioLevel = audioAsync.value ?? 0.0;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return CustomPaint(
          size: const Size(80, 20),
          painter: WaveformPainter(
            audioLevel: audioLevel,
            animationValue: controller.value,
          ),
        );
      },
    );
  }
}
