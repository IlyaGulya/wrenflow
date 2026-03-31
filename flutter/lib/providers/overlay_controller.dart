import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/overlay_service.dart';
import '../src/bindings/signals/signals.dart';
import 'audio_level_provider.dart';
import 'pipeline_state_provider.dart';

/// Bridges pipeline state + audio levels to the native overlay panel.
///
/// Created once at app startup, same pattern as SystemTrayManager.
class OverlayController {
  OverlayController(this._container);

  final ProviderContainer _container;
  final _overlay = OverlayService();
  String? _currentPhase;

  void init() {
    _container.listen<AsyncValue<PipelineState>>(
      pipelineStateProvider,
      (previous, next) {
        final state = next.value;
        if (state != null) _onPipelineState(state);
      },
    );

    _container.listen<AsyncValue<double>>(
      audioLevelProvider,
      (previous, next) {
        final level = next.value;
        if (level != null && _currentPhase == 'recording') {
          _overlay.updateAudioLevel(level);
        }
      },
    );
  }

  void _onPipelineState(PipelineState state) {
    switch (state) {
      case PipelineStateStarting() || PipelineStateInitializing():
        _currentPhase = 'initializing';
        _overlay.show('initializing');

      case PipelineStateRecording():
        _currentPhase = 'recording';
        _overlay.show('recording');

      case PipelineStateTranscribing(showingIndicator: true):
        _currentPhase = 'transcribing';
        _overlay.show('transcribing');

      case PipelineStateTranscribing(showingIndicator: false):
        _currentPhase = null;
        _overlay.hide();

      case PipelineStatePasting() ||
           PipelineStateIdle() ||
           PipelineStateError():
        _currentPhase = null;
        _overlay.hide();

      default:
        _currentPhase = null;
        _overlay.hide();
    }
  }
}
