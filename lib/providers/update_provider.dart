import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/update_service.dart';
import '../shell/shell_capabilities.dart';
import '../src/bindings/signals/signals.dart' as sig;
import 'rust_snapshot_bridge.dart';

enum UpdatePhase { unsupported, idle, checking, upToDate, available, error }

class UpdateState {
  const UpdateState({
    required this.phase,
    this.latestVersion = '',
    this.releaseUrl = '',
    this.downloadUrl = '',
    this.publishedAt,
    this.errorMessage,
  });

  const UpdateState.unsupported() : this(phase: UpdatePhase.unsupported);
  const UpdateState.idle() : this(phase: UpdatePhase.idle);
  const UpdateState.checking() : this(phase: UpdatePhase.checking);
  const UpdateState.upToDate() : this(phase: UpdatePhase.upToDate);
  const UpdateState.available({
    required String latestVersion,
    required String releaseUrl,
    required String downloadUrl,
    DateTime? publishedAt,
  }) : this(
         phase: UpdatePhase.available,
         latestVersion: latestVersion,
         releaseUrl: releaseUrl,
         downloadUrl: downloadUrl,
         publishedAt: publishedAt,
       );
  const UpdateState.error(String message)
    : this(phase: UpdatePhase.error, errorMessage: message);

  final UpdatePhase phase;
  final String latestVersion;
  final String releaseUrl;
  final String downloadUrl;
  final DateTime? publishedAt;
  final String? errorMessage;

  bool get isRecent {
    if (publishedAt == null) return false;
    return DateTime.now().difference(publishedAt!).inHours < 72;
  }
}

class UpdateNotifier extends RustSnapshotNotifier<UpdateState> {
  static const _checkInterval = Duration(hours: 6);

  Timer? _refreshTimer;

  @override
  UpdateState build() {
    _startSnapshotBridge();

    final capabilities = ref.read(shellCapabilitiesProvider);
    if (!capabilities.updates) {
      _reportStatus(const sig.UpdateStatusUnsupported());
      return const UpdateState.unsupported();
    }

    _refreshTimer = Timer.periodic(_checkInterval, (_) => _checkAndReport());
    Future<void>.delayed(const Duration(seconds: 5), _checkAndReport);

    ref.onDispose(() {
      _refreshTimer?.cancel();
    });

    return const UpdateState.idle();
  }

  void _startSnapshotBridge() {
    bindRustSnapshotState<sig.UpdatesSnapshotChanged>(
      requestSnapshot: () =>
          const sig.RequestUpdatesSnapshot().sendSignalToRust(),
      signalStream: sig.UpdatesSnapshotChanged.rustSignalStream,
      map: (message) => _fromSignalStatus(message.status),
    );
  }

  void _reportStatus(sig.UpdateStatus status) {
    sig.ReportUpdatesStatus(status: status).sendSignalToRust();
  }

  UpdateState _fromSignalStatus(sig.UpdateStatus status) {
    return switch (status) {
      sig.UpdateStatusUnsupported() => const UpdateState.unsupported(),
      sig.UpdateStatusIdle() => const UpdateState.idle(),
      sig.UpdateStatusChecking() => const UpdateState.checking(),
      sig.UpdateStatusUpToDate() => const UpdateState.upToDate(),
      sig.UpdateStatusAvailable() => UpdateState.available(
        latestVersion: status.latestVersion,
        releaseUrl: status.releaseUrl,
        downloadUrl: status.downloadUrl,
        publishedAt: status.publishedAtIso == null
            ? null
            : DateTime.tryParse(status.publishedAtIso!),
      ),
      sig.UpdateStatusError() => UpdateState.error(status.message),
      _ => const UpdateState.idle(),
    };
  }

  sig.UpdateStatus _toSignalStatus(UpdateInfo info) {
    if (!info.isAvailable) {
      return const sig.UpdateStatusUpToDate();
    }

    return sig.UpdateStatusAvailable(
      latestVersion: info.latestVersion,
      releaseUrl: info.releaseUrl,
      downloadUrl: info.downloadUrl,
      publishedAtIso: info.publishedAt?.toIso8601String(),
    );
  }

  Future<void> _checkAndReport() async {
    _reportStatus(const sig.UpdateStatusChecking());
    try {
      final source = GitHubUpdateSource();
      final info = await source.checkForUpdate();
      _reportStatus(_toSignalStatus(info));
    } catch (error) {
      _reportStatus(sig.UpdateStatusError(message: error.toString()));
    }
  }

  Future<void> checkNow() => _checkAndReport();
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
