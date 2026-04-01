import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

    return modelStateAsync.when(
      loading: () => _buildNotDownloaded(),
      error: (error, _) => _buildError(error.toString()),
      data: (state) => switch (state) {
        ModelStateNotDownloaded() => _buildNotDownloaded(),
        ModelStateDownloading() => _buildDownloading(state),
        ModelStateLoading() => _buildLoading(),
        ModelStateWarming() => _buildWarming(),
        ModelStateReady() => _buildReady(),
        ModelStateError() => _buildError(state.message),
        _ => _buildNotDownloaded(),
      },
    );
  }

  Widget _buildNotDownloaded() {
    return _CardContainer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.arrow_down_circle,
            size: 40,
            color: CupertinoColors.activeBlue,
          ),
          const SizedBox(height: 12),
          const Text(
            'Local Transcription Model',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Download the Parakeet speech-to-text model for '
            'fast, private, on-device transcription.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF8E8E93),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: () {
                const InitializeLocalModel().sendSignalToRust();
              },
              child: const Text(
                'Download Parakeet model (~400 MB)',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloading(ModelStateDownloading state) {
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
              const Text(
                'Downloading model...',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
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
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8E8E93),
                ),
              ),
              Text(
                '$eta remaining',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8E8E93),
                ),
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

  Widget _buildLoading() {
    return const _CardContainer(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CupertinoActivityIndicator(),
          ),
          SizedBox(width: 12),
          Text(
            'Loading model...',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8E8E93),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarming() {
    return const _CardContainer(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CupertinoActivityIndicator(),
          ),
          SizedBox(width: 12),
          Text(
            'Warming up model...',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8E8E93),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReady() {
    return const _CardContainer(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.check_mark_circled_solid,
            color: CupertinoColors.activeGreen,
            size: 22,
          ),
          SizedBox(width: 10),
          Text(
            'Model ready',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.activeGreen,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
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
          const Text(
            'Download failed',
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
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF8E8E93),
            ),
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
