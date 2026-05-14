import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rinf/rinf.dart';

import '../providers/audio_level_provider.dart';
import '../src/bindings/signals/signals.dart';
import 'overlay_shell.dart';
import 'shell_pipeline_presentation.dart';

/// Bridges pipeline state + audio levels to the native overlay panel.
///
/// Created once at app startup, same pattern as SystemTrayManager.
class OverlayController {
  OverlayController(this._container);

  final ProviderContainer _container;
  final _overlay = platformOverlayShell;
  OverlayPhase _currentPhase = OverlayPhase.hidden;
  StreamSubscription<RustSignalPack<PipelineError>>? _errorSub;

  void init() {
    _container.listen<ShellPipelinePresentation>(shellPipelinePresentationProvider, (
      previous,
      next,
    ) {
      _onPipelinePresentation(next);
    });

    _container.listen<AsyncValue<double>>(audioLevelProvider, (previous, next) {
      final level = next.value;
      if (level != null && _currentPhase == OverlayPhase.recording) {
        _overlay.updateAudioLevel(level);
      }
    });

    // Show error toasts from Rust pipeline errors.
    _errorSub = PipelineError.rustSignalStream.listen((signalPack) {
      _overlay.showError(signalPack.message.message);
    });
  }

  Future<void> dispose() async {
    await _errorSub?.cancel();
  }

  void _onPipelinePresentation(ShellPipelinePresentation presentation) {
    _currentPhase = presentation.overlayPhase;
    switch (presentation.overlayPhase) {
      case OverlayPhase.hidden:
        _overlay.hide();
      case OverlayPhase.initializing:
        _overlay.show('initializing');
      case OverlayPhase.recording:
        _overlay.show('recording');
      case OverlayPhase.transcribing:
        _overlay.show('transcribing');
    }
  }
}
