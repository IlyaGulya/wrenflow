import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/bindings/signals/signals.dart';
import 'audio_level_provider.dart';
import 'latest_transcript_provider.dart';
import 'local_model_status_provider.dart';
import 'local_models_provider.dart';
import 'model_state_provider.dart';
import 'pipeline_state_provider.dart';
import 'runtime_capabilities_provider.dart';

enum TranscriptionTestPhase {
  loadingCatalog,
  modelDownloading,
  modelLoading,
  modelWarming,
  modelError,
  modelManual,
  modelPending,
  runtimeUnavailable,
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
      final selectedModelOperation = ref.watch(selectedModelRuntimeStateProvider);
      final globalModelOperation = ref.watch(globalModelOperationProvider);
      final runtimeCapabilities = ref.watch(runtimeCapabilitiesProvider).value;
      final modelState = selectedModelOperation?.state;
      final models = ref.watch(localModelsProvider);
      final modelStatus = ref.watch(localModelsStatusProvider);
      final selectedModel = ref.watch(selectedLocalModelProvider);
      final busyOperation = globalModelOperation?.isBusy == true
          ? globalModelOperation
          : selectedModelOperation;
      final operationModelId = busyOperation?.modelId;
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

      if (runtimeCapabilities == null) {
        return const TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.loadingCatalog,
          message: 'Loading runtime support...',
        );
      }

      if (!runtimeCapabilities.audioCapture) {
        return const TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.runtimeUnavailable,
          message: 'Audio capture is unavailable in the current runtime.',
        );
      }

      if (!runtimeCapabilities.localTranscription) {
        return const TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.runtimeUnavailable,
          message: 'Local transcription is unavailable in the current runtime.',
        );
      }

      if (!runtimeCapabilities.modelActivation) {
        return const TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.runtimeUnavailable,
          message: 'Model activation is unavailable in the current runtime.',
        );
      }

      if (!selectedModel.supportsCurrentRuntime) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.runtimeUnavailable,
          message:
              '${selectedModel.displayName} is not supported by the current runtime.',
        );
      }

      final modelName = operationModel?.displayName ?? selectedModel.displayName;
      final isInstalled = modelStatus.isInstalled(selectedModel.id);
      final isActive = modelStatus.isActive(selectedModel.id);

      if (busyOperation?.state case final ModelStateDownloading downloading) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelDownloading,
          message: 'Downloading $modelName',
          progress: downloading.progress,
        );
      }
      if (busyOperation?.state is ModelStateLoading) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelLoading,
          message: 'Loading $modelName...',
        );
      }
      if (busyOperation?.state is ModelStateWarming) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelWarming,
          message: 'Warming up $modelName...',
        );
      }
      if (modelState is ModelStateError) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelError,
          message: '$modelName failed. Open its card and retry.',
        );
      }
      if (!isActive) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelManual,
          message: isInstalled
              ? '${selectedModel.displayName} is selected but not active yet. Use its card to activate it.'
              : '${selectedModel.displayName} is selected but not installed yet. Use its card to download and activate it.',
        );
      }
      if (modelState is! ModelStateReady) {
        return TranscriptionTestPresentation(
          phase: TranscriptionTestPhase.modelPending,
          message: 'Use the selected model card to finish preparing ${selectedModel.displayName}.',
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
