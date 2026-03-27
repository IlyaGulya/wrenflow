import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wrenflow/providers/audio_level_provider.dart';
import 'package:wrenflow/providers/pipeline_state_provider.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';
import 'package:wrenflow/widgets/waveform_painter.dart';

/// Floating overlay that shows recording status.
///
/// Visible whenever the pipeline is active (Starting through Pasting) and
/// hidden when Idle. Displays phase-appropriate content:
///   - Starting / Initializing: loading spinner
///   - Recording: animated waveform driven by audio level
///   - Transcribing: spinner with "Transcribing..." label
///   - Pasting: checkmark with "Done" label (auto-dismisses)
class RecordingOverlay extends ConsumerWidget {
  const RecordingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pipelineAsync = ref.watch(pipelineStateProvider);

    final state = pipelineAsync.value;

    // Not visible when idle, on error, or before the first signal arrives.
    if (state == null ||
        state is PipelineStateIdle ||
        state is PipelineStateError) {
      return const SizedBox.shrink();
    }

    return _AnimatedOverlayContainer(state: state);
  }
}

// ---------------------------------------------------------------------------
// Internal stateful wrapper -- owns the AnimationController for the waveform
// idle loop and the cross-fade between phases.
// ---------------------------------------------------------------------------

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
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.80),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.40),
              blurRadius: 24,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: _buildPhaseContent(widget.state),
        ),
      ),
    );
  }

  Widget _buildPhaseContent(PipelineState state) {
    return switch (state) {
      PipelineStateStarting() || PipelineStateInitializing() =>
        _LoadingContent(key: const ValueKey('loading')),
      PipelineStateRecording() => _RecordingContent(
        key: const ValueKey('recording'),
        controller: _controller,
        ref: ref,
      ),
      PipelineStateTranscribing() =>
        _TranscribingContent(key: const ValueKey('transcribing')),
      PipelineStatePasting() =>
        _DoneContent(key: const ValueKey('done')),
      // Idle/Error are filtered out in the parent widget, but the
      // exhaustiveness checker needs a default branch.
      _ => const SizedBox.shrink(),
    };
  }
}

// ---------------------------------------------------------------------------
// Phase-specific content widgets
// ---------------------------------------------------------------------------

class _LoadingContent extends StatelessWidget {
  const _LoadingContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white70,
          ),
        ),
        SizedBox(width: 12),
        Text(
          'Starting...',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PulsingDot(controller: controller),
        const SizedBox(width: 12),
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return CustomPaint(
              size: const Size(48, 28),
              painter: WaveformPainter(
                audioLevel: audioLevel,
                animationValue: controller.value,
                barColor: Colors.white,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _PulsingDot extends StatelessWidget {
  const _PulsingDot({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        // Gentle pulse: opacity oscillates between 0.6 and 1.0.
        final t = math.sin(controller.value * 2 * math.pi);
        final pulse = 0.6 + 0.4 * (t + 1) / 2;
        return Opacity(
          opacity: pulse,
          child: child,
        );
      },
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _TranscribingContent extends StatelessWidget {
  const _TranscribingContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white70,
          ),
        ),
        SizedBox(width: 12),
        Text(
          'Transcribing...',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _DoneContent extends StatelessWidget {
  const _DoneContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, color: Colors.greenAccent, size: 22),
        SizedBox(width: 10),
        Text(
          'Done',
          style: TextStyle(
            color: Colors.greenAccent,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
