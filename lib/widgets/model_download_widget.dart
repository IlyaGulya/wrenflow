import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wrenflow/providers/local_models_provider.dart';
import 'package:wrenflow/providers/local_model_status_provider.dart';
import 'package:wrenflow/providers/model_state_provider.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

/// Widget that displays the current model download/load state and allows the
/// user to trigger a download, cancel an in-progress download, or retry after
/// an error.
///
/// Designed to be embedded in both the setup wizard and the settings screen.
class ModelDownloadWidget extends ConsumerWidget {
  const ModelDownloadWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelStateAsync = ref.watch(modelStateProvider);
    final modelsStatus = ref.watch(localModelsStatusProvider).value;
    final localModels = ref.watch(localModelsProvider);
    final fallbackSelectedModel = ref.watch(selectedLocalModelProvider);
    final selectedModelId =
        modelsStatus?.selectedModelId ?? fallbackSelectedModel.id;
    final selectedModel = localModels.firstWhere(
      (model) => model.id == selectedModelId,
      orElse: () => fallbackSelectedModel,
    );
    final isInstalled = modelsStatus?.isInstalled(selectedModel.id) ?? false;
    final isActive = modelsStatus?.isActive(selectedModel.id) ?? false;
    final activeModelId = modelsStatus?.activeModelId;
    final activeModel = activeModelId == null
        ? null
        : localModels.where((model) => model.id == activeModelId).isEmpty
        ? null
        : localModels.firstWhere((model) => model.id == activeModelId);
    final operation = modelStateAsync.value;
    final operationModelId = operation?.modelId;
    final operationModel = operationModelId == null
        ? null
        : localModels.where((model) => model.id == operationModelId).isEmpty
        ? null
        : localModels.firstWhere((model) => model.id == operationModelId);

    if (!selectedModel.isAvailable) {
      return _buildUnavailable(selectedModel);
    }

    return modelStateAsync.when(
      loading: () => _buildIdle(
        selectedModel,
        isInstalled: isInstalled,
        isActive: isActive,
      ),
      error: (error, _) =>
          _buildError(error.toString(), selectedModel.displayName),
      data: (operationState) => switch (operationState.state) {
        ModelStateNotDownloaded() => _buildIdle(
          selectedModel,
          isInstalled: isInstalled,
          isActive: isActive,
          activeModelName: activeModel?.displayName,
        ),
        ModelStateDownloading() => _buildDownloading(
          operationState.state as ModelStateDownloading,
          operationModel?.displayName ?? selectedModel.displayName,
        ),
        ModelStateLoading() => _buildLoading(
          operationModel?.displayName ?? selectedModel.displayName,
        ),
        ModelStateWarming() => _buildWarming(
          operationModel?.displayName ?? selectedModel.displayName,
        ),
        ModelStateReady() =>
          isActive
              ? _buildReady(
                  activeModel?.displayName ?? selectedModel.displayName,
                )
              : _buildIdle(
                  selectedModel,
                  isInstalled: isInstalled,
                  isActive: isActive,
                  activeModelName: activeModel?.displayName,
                ),
        ModelStateError() => _buildError(
          (operationState.state as ModelStateError).message,
          operationModel?.displayName ?? selectedModel.displayName,
        ),
        _ => _buildIdle(
          selectedModel,
          isInstalled: isInstalled,
          isActive: isActive,
          activeModelName: activeModel?.displayName,
        ),
      },
    );
  }

  Widget _buildUnavailable(LocalModelDescriptor selectedModel) {
    return _CardContainer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.lock_circle,
            size: 40,
            color: CupertinoColors.systemGrey,
          ),
          const SizedBox(height: 12),
          Text(
            selectedModel.displayName,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            selectedModel.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
          ),
          const SizedBox(height: 16),
          const Text(
            'This model is not shipped in the current build yet.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
          ),
        ],
      ),
    );
  }

  Widget _buildIdle(
    LocalModelDescriptor selectedModel, {
    required bool isInstalled,
    required bool isActive,
    String? activeModelName,
  }) {
    final primaryLabel = isInstalled
        ? (isActive ? 'Active' : 'Activate ${selectedModel.displayName}')
        : 'Download & Activate ${selectedModel.displayName}';

    final subtitle = isActive
        ? '${selectedModel.displayName} is the active transcription model.'
        : isInstalled
        ? activeModelName != null
              ? '$activeModelName is active right now. ${selectedModel.displayName} is installed and ready to activate.'
              : '${selectedModel.displayName} is installed and ready to activate.'
        : 'Selecting a model does not start anything automatically. Use the button below when you want to install and activate it.';

    return _CardContainer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isInstalled
                ? (isActive ? 'Current Active Model' : 'Ready To Activate')
                : 'Manual Activation',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: isActive
                  ? null
                  : () {
                      const InitializeLocalModel().sendSignalToRust();
                    },
              child: Text(
                primaryLabel,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloading(ModelStateDownloading state, String modelName) {
    final progressPercent = (state.progress * 100).clamp(0.0, 100.0);
    final speedMBps = state.speedBps / 1000000;
    final eta = _formatEta(state.etaSecs);

    return _CardContainer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Downloading $modelName...',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              Text(
                '${progressPercent.toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.activeBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.progress.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: const Color(0xFFE0E0E0),
              valueColor: const AlwaysStoppedAnimation<Color>(
                CupertinoColors.activeBlue,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${speedMBps.toStringAsFixed(1)} MB/s',
                style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
              ),
              Text(
                '$eta remaining',
                style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 10),
              color: const Color(0xFFF5F5F7),
              onPressed: () {
                const CancelModelDownload().sendSignalToRust();
              },
              child: const Text(
                'Cancel',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: CupertinoColors.destructiveRed,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(String modelName) {
    return _CardContainer(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CupertinoActivityIndicator(),
          ),
          const SizedBox(width: 12),
          Text(
            'Loading $modelName...',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8E8E93),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarming(String modelName) {
    return _CardContainer(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CupertinoActivityIndicator(),
          ),
          const SizedBox(width: 12),
          Text(
            'Warming up $modelName...',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8E8E93),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReady(String modelName) {
    return _CardContainer(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            CupertinoIcons.check_mark_circled_solid,
            color: CupertinoColors.activeGreen,
            size: 22,
          ),
          const SizedBox(width: 10),
          Text(
            '$modelName ready',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.activeGreen,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message, String modelName) {
    return _CardContainer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_triangle_fill,
            color: CupertinoColors.destructiveRed,
            size: 32,
          ),
          const SizedBox(height: 10),
          Text(
            '$modelName failed',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.destructiveRed,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: () {
                const InitializeLocalModel().sendSignalToRust();
              },
              child: const Text(
                'Retry',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Format seconds as mm:ss. Returns "--:--" when the ETA is not meaningful.
  static String _formatEta(double etaSecs) {
    if (etaSecs.isNaN || etaSecs.isInfinite || etaSecs < 0) {
      return '--:--';
    }
    final totalSeconds = etaSecs.round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}

/// Shared card container that matches the settings screen visual style.
class _CardContainer extends StatelessWidget {
  const _CardContainer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 1,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: child,
    );
  }
}
