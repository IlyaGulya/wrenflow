import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/pipeline_state_provider.dart';
import '../src/bindings/signals/signals.dart';

enum TrayIconVariant { idle, recording, transcribing }

enum OverlayPhase { hidden, initializing, recording, transcribing }

class ShellPipelinePresentation {
  const ShellPipelinePresentation({
    required this.statusText,
    required this.trayIcon,
    required this.overlayPhase,
  });

  final String statusText;
  final TrayIconVariant trayIcon;
  final OverlayPhase overlayPhase;
}

const _idlePipelinePresentation = ShellPipelinePresentation(
  statusText: 'Ready',
  trayIcon: TrayIconVariant.idle,
  overlayPhase: OverlayPhase.hidden,
);

final shellPipelinePresentationProvider = Provider<ShellPipelinePresentation>((
  ref,
) {
  final pipeline = ref.watch(pipelineStateProvider).value;
  if (pipeline == null) return _idlePipelinePresentation;
  return _mapPipelinePresentation(pipeline);
});

ShellPipelinePresentation _mapPipelinePresentation(PipelineState state) {
  return switch (state) {
    PipelineStateIdle() => _idlePipelinePresentation,
    PipelineStateStarting() || PipelineStateInitializing() =>
      const ShellPipelinePresentation(
        statusText: 'Initializing...',
        trayIcon: TrayIconVariant.idle,
        overlayPhase: OverlayPhase.initializing,
      ),
    PipelineStateRecording() => const ShellPipelinePresentation(
      statusText: 'Recording...',
      trayIcon: TrayIconVariant.recording,
      overlayPhase: OverlayPhase.recording,
    ),
    PipelineStateTranscribing(showingIndicator: true) =>
      const ShellPipelinePresentation(
        statusText: 'Transcribing...',
        trayIcon: TrayIconVariant.transcribing,
        overlayPhase: OverlayPhase.transcribing,
      ),
    PipelineStateTranscribing(showingIndicator: false) =>
      const ShellPipelinePresentation(
        statusText: 'Transcribing...',
        trayIcon: TrayIconVariant.transcribing,
        overlayPhase: OverlayPhase.hidden,
      ),
    PipelineStatePasting() => const ShellPipelinePresentation(
      statusText: 'Pasting...',
      trayIcon: TrayIconVariant.idle,
      overlayPhase: OverlayPhase.hidden,
    ),
    PipelineStateError() => const ShellPipelinePresentation(
      statusText: 'Error',
      trayIcon: TrayIconVariant.idle,
      overlayPhase: OverlayPhase.hidden,
    ),
    _ => _idlePipelinePresentation,
  };
}
