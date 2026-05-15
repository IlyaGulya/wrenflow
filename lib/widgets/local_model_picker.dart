import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/local_models_provider.dart';
import '../providers/local_model_status_provider.dart';
import '../providers/model_state_provider.dart';
import '../providers/settings_provider.dart';
import '../src/bindings/signals/signals.dart';
import '../theme/wrenflow_theme.dart';

class LocalModelPicker extends ConsumerWidget {
  const LocalModelPicker({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(localModelsProvider);
    final modelStatus = ref.watch(localModelsStatusProvider);
    final snapshot = ref.watch(localModelsSnapshotProvider).value;
    final globalOperation = ref.watch(globalModelOperationProvider);
    final selectedId = modelStatus?.selectedModelId;

    if (models.isEmpty) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 10 : 12),
        decoration: BoxDecoration(
          color: WrenflowStyle.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: WrenflowStyle.border, width: 1),
        ),
        child: Text(
          'Loading available models...',
          style: WrenflowStyle.caption(11),
        ),
      );
    }

    return Column(
      children: models.map((model) {
        final isSelected = model.id == selectedId;
        final isInstalled = modelStatus?.isInstalled(model.id) ?? false;
        final isActive = modelStatus?.isActive(model.id) ?? false;
        final canSelect = model.isAvailable && model.supportsCurrentRuntime;
        final directState = snapshot?.stateFor(model.id);
        final effectiveState =
            globalOperation?.modelId == model.id && globalOperation?.isBusy == true
            ? globalOperation!.state
            : directState;
        final activeMatches = modelStatus?.activeModelId == null
            ? const <LocalModelDescriptor>[]
            : models
                  .where((candidate) => candidate.id == modelStatus!.activeModelId)
                  .toList(growable: false);
        final activeModelName = activeMatches.isEmpty
            ? null
            : activeMatches.first.displayName;
        return GestureDetector(
          onTap: canSelect
              ? () => ref
                    .read(settingsProvider.notifier)
                    .setSelectedLocalModelId(model.id)
              : null,
          child: Opacity(
            opacity: canSelect ? 1 : 0.55,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.all(compact ? 10 : 12),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: isSelected ? WrenflowStyle.textOp05 : WrenflowStyle.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? WrenflowStyle.textOp15
                      : WrenflowStyle.border,
                  width: 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      isSelected
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      size: 15,
                      color: isSelected
                          ? WrenflowStyle.green
                          : WrenflowStyle.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                model.displayName,
                                style: WrenflowStyle.body(
                                  12,
                                ).copyWith(fontWeight: FontWeight.w500),
                              ),
                            ),
                            _ModelBadge(label: model.runtimeLabel),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(model.subtitle, style: WrenflowStyle.caption(11)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _ModelBadge(label: model.family),
                            _ModelBadge(label: model.downloadLabel),
                            if (isActive) const _ModelBadge(label: 'Active'),
                            if (isSelected && !isActive)
                              const _ModelBadge(label: 'Selected'),
                            if (isInstalled && !isActive)
                              const _ModelBadge(label: 'Installed'),
                            if (model.isRecommended)
                              const _ModelBadge(label: 'Default'),
                            if (!model.supportsCurrentRuntime)
                              const _ModelBadge(label: 'Runtime Unsupported'),
                            if (!model.isAvailable)
                              const _ModelBadge(label: 'Coming Next'),
                          ],
                        ),
                        if (!compact) ...[
                          const SizedBox(height: 8),
                          Text(
                            !model.isAvailable
                                ? 'This model is not shipped in the current build yet.'
                                : !model.supportsCurrentRuntime
                                ? 'This build cannot run ${model.displayName} yet.'
                                : isActive
                                ? 'Currently active for transcription.'
                                : isSelected
                                ? isInstalled
                                      ? 'Selected as preferred. Use the action below when you want to switch.'
                                      : 'Selected as preferred. Download and activate it from this card.'
                                : isInstalled
                                ? 'Installed locally. Select it to make it your preferred model.'
                                : 'Available, but not selected.',
                            style: WrenflowStyle.caption(10),
                          ),
                        ],
                        if (isSelected && canSelect) ...[
                          const SizedBox(height: 10),
                          _SelectedModelActionSection(
                            model: model,
                            modelState: effectiveState,
                            isInstalled: isInstalled,
                            isActive: isActive,
                            activeModelName: activeModelName,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _SelectedModelActionSection extends StatelessWidget {
  const _SelectedModelActionSection({
    required this.model,
    required this.modelState,
    required this.isInstalled,
    required this.isActive,
    required this.activeModelName,
  });

  final LocalModelDescriptor model;
  final ModelState? modelState;
  final bool isInstalled;
  final bool isActive;
  final String? activeModelName;

  @override
  Widget build(BuildContext context) {
    if (modelState case final ModelStateDownloading downloading) {
      final progress = (downloading.progress * 100).clamp(0.0, 100.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Downloading ${model.displayName}...',
            style: WrenflowStyle.caption(10),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: downloading.progress.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: WrenflowStyle.textOp10,
              valueColor: AlwaysStoppedAnimation(WrenflowStyle.textOp50),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${progress.toStringAsFixed(0)}% • ${_progressDetails(downloading)}',
                  style: WrenflowStyle.caption(10),
                ),
              ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: () => const CancelModelDownload().sendSignalToRust(),
                child: Text(
                  'Cancel',
                  style: WrenflowStyle.body(
                    11,
                  ).copyWith(color: WrenflowStyle.red),
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (modelState is ModelStateLoading || modelState is ModelStateWarming) {
      final verb = modelState is ModelStateWarming ? 'Warming up' : 'Loading';
      return Row(
        children: [
          const CupertinoActivityIndicator(radius: 7),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$verb ${model.displayName}...',
              style: WrenflowStyle.caption(10),
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            onPressed: () => const CancelModelDownload().sendSignalToRust(),
            child: Text(
              'Cancel',
              style: WrenflowStyle.body(11).copyWith(color: WrenflowStyle.red),
            ),
          ),
        ],
      );
    }

    if (modelState case final ModelStateError error) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            error.message,
            style: WrenflowStyle.caption(10).copyWith(color: WrenflowStyle.red),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              onPressed: () => const InitializeLocalModel().sendSignalToRust(),
              child: Text(
                isInstalled
                    ? 'Retry activation'
                    : 'Download & activate',
                style: WrenflowStyle.body(11).copyWith(
                  color: CupertinoColors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final statusText = isActive
        ? '${model.displayName} is active now.'
        : isInstalled
        ? activeModelName != null
              ? '$activeModelName is active now. Activate ${model.displayName} when you want to switch.'
              : '${model.displayName} is installed and ready to activate.'
        : '${model.displayName} is not downloaded yet.';
    final buttonLabel = isActive
        ? 'Active'
        : isInstalled
        ? 'Activate now'
        : 'Download & activate';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(statusText, style: WrenflowStyle.caption(10)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: CupertinoButton.filled(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            onPressed: isActive
                ? null
                : () => const InitializeLocalModel().sendSignalToRust(),
            child: Text(
              buttonLabel,
              style: WrenflowStyle.body(11).copyWith(
                color: CupertinoColors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _progressDetails(ModelStateDownloading downloading) {
    final speedBps = downloading.speedBps;
    final etaSecs = downloading.etaSecs;
    final speedLabel = speedBps > 0
        ? '${(speedBps / 1000000).toStringAsFixed(1)} MB/s'
        : 'Preparing...';
    if (etaSecs <= 0) return speedLabel;
    final eta = Duration(seconds: etaSecs.round());
    final minutes = eta.inMinutes;
    final seconds = eta.inSeconds.remainder(60);
    final etaLabel = minutes > 0 ? '${minutes}m ${seconds}s left' : '${seconds}s left';
    return '$speedLabel • $etaLabel';
  }
}

class _ModelBadge extends StatelessWidget {
  const _ModelBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: WrenflowStyle.textOp05,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: WrenflowStyle.border, width: 1),
      ),
      child: Text(
        label,
        style: WrenflowStyle.mono(
          9,
        ).copyWith(color: WrenflowStyle.textSecondary),
      ),
    );
  }
}
