import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/local_models_provider.dart';
import '../providers/local_model_status_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/wrenflow_theme.dart';

class LocalModelPicker extends ConsumerWidget {
  const LocalModelPicker({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(localModelsProvider);
    final modelStatus = ref.watch(localModelsStatusProvider);
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
        return GestureDetector(
          onTap: model.isAvailable
              ? () => ref
                    .read(settingsProvider.notifier)
                    .setSelectedLocalModelId(model.id)
              : null,
          child: Opacity(
            opacity: model.isAvailable ? 1 : 0.55,
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
                            if (!model.isAvailable)
                              const _ModelBadge(label: 'Coming Next'),
                          ],
                        ),
                        if (model.isAvailable && !compact) ...[
                          const SizedBox(height: 8),
                          Text(
                            isActive
                                ? 'Currently active for transcription.'
                                : isSelected
                                ? isInstalled
                                      ? 'Selected as preferred. Activate it explicitly below.'
                                      : 'Selected as preferred. Download and activate it explicitly below.'
                                : isInstalled
                                ? 'Installed locally. Select it to make it your preferred model.'
                                : 'Available, but not selected.',
                            style: WrenflowStyle.caption(10),
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
