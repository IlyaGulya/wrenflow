import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/bindings/signals/signals.dart';
import 'audio_level_provider.dart';
import 'latest_transcript_provider.dart';
import 'local_model_status_provider.dart';
import 'local_models_provider.dart';
import 'model_state_provider.dart';
import 'pipeline_state_provider.dart';

enum TranscriptionTestPhase {
  loadingCatalog,
  modelDownloading,
  modelLoading,
  modelWarming,
  modelError,
  modelManual,
  modelPending,
  transcript,
  recording,
  starting,
  transcribing,
  pipelineError,
  idle,
}

class TranscriptionTestPresentation {
  const TranscriptionTestPresentation({
    required this.phase,
    this.message,
    this.progress,
    this.audioLevel,
  });

  final TranscriptionTestPhase phase;
  final String? message;
  final double? progress;
  final double? audioLevel;
}

final transcriptionTestPresentationProvider =
    Provider<TranscriptionTestPresentation>((ref) {
      final pipeline = ref.watch(pipelineStateProvider).value;
      final latestTranscript = ref.watch(latestTranscriptProvider).value;
      final modelOperation = ref.watch(selectedModelStateProvider);
      final modelState = modelOperation?.state;
      final models = ref.watch(localModelsProvider);
      final modelStatus = ref.watch(localModelsStatusProvider);
      final selectedModel = ref.watch(selectedLocalModelProvider);
      final operationModelId = modelOperation?.modelId;
      final operationModel = operationModelId == null
          ? null
          : models.where((model) => model.id == operationModelId).isEmpty
          ? null
          : models.firstWhere((model) => model.id == operationModelId);

      if (models.isEmpty || modelStatus == null || selectedModel == null) {
        return const TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.loadingCatalog,
          message: 'Loading available models...',
        );
      }

      final modelName = operationModel?.displayName ?? selectedModel.displayName;
      final isInstalled = modelStatus.isInstalled(selectedModel.id);
      final isActive = modelStatus.isActive(selectedModel.id);

      if (modelState is ModelStateDownloading) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelDownloading,
          message: 'Downloading $modelName',
          progress: modelState.progress,
        );
      }
      if (modelState is ModelStateLoading) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelLoading,
          message: 'Loading $modelName...',
        );
      }
      if (modelState is ModelStateWarming) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelWarming,
          message: 'Warming up $modelName...',
        );
      }
      if (modelState is ModelStateError) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelError,
          message: '$modelName failed. Tap to retry.',
        );
      }
      if (!isActive) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelManual,
          message: isInstalled
              ? '${selectedModel.displayName} is selected but not active yet.'
              : '${selectedModel.displayName} is selected but not installed yet.',
        );
      }
      if (modelState is! ModelStateReady) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelPending,
          message: 'Activate ${selectedModel.displayName} to run a live test.',
        );
      }

      if (pipeline is PipelineStateStarting ||
          pipeline is PipelineStateRecording) {
        if (pipeline is PipelineStateRecording) {
          return TranscriptionTestPresentation(
            phase: TranscriptionTestPhase.recording,
            audioLevel: ref.watch(audioLevelProvider).value ?? 0.0,
          );
        }
        return const TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.starting,
          message: 'Starting...',
        );
      }

      if (pipeline is PipelineStateTranscribing) {
        return const TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.transcribing,
          message: 'Transcribing...',
        );
      }

      if (pipeline is PipelineStateError) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.pipelineError,
          message: pipeline.message,
        );
      }

      if (latestTranscript != null && latestTranscript.isNotEmpty) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.transcript,
          message: latestTranscript,
        );
      }

      return const TranscriptionTestPresentation(
        phase: TranscriptionTestPhase.idle,
        message: 'Press and hold your hotkey now to test.',
      );
    });
