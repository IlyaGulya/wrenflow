import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/services/launch_at_login_service.dart';
import '../src/bindings/signals/signals.dart' as sig;

@immutable
class LaunchAtLoginState {
  const LaunchAtLoginState({
    required this.enabled,
    required this.isLoading,
    this.errorMessage,
  });

  const LaunchAtLoginState.initial()
    : enabled = false,
      isLoading = true,
      errorMessage = null;

  final bool enabled;
  final bool isLoading;
  final String? errorMessage;

  LaunchAtLoginState copyWith({
    bool? enabled,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
  }) {
    return LaunchAtLoginState(
      enabled: enabled ?? this.enabled,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class LaunchAtLoginNotifier extends Notifier<LaunchAtLoginState> {
  final _service = LaunchAtLoginService();
  StreamSubscription? _snapshotSub;

  @override
  LaunchAtLoginState build() {
    _snapshotSub = sig.LaunchAtLoginSnapshotChanged.rustSignalStream.listen((
      signalPack,
    ) {
      final snapshot = signalPack.message.snapshot;
      state = LaunchAtLoginState(
        enabled: snapshot.enabled,
        isLoading: snapshot.isLoading,
        errorMessage: snapshot.errorMessage,
      );
    });

    const sig.RequestLaunchAtLoginSnapshot().sendSignalToRust();
    ref.onDispose(() => _snapshotSub?.cancel());
    unawaited(refresh());
    return const LaunchAtLoginState.initial();
  }

  void _reportSnapshot(LaunchAtLoginState snapshot) {
    sig.ReportLaunchAtLoginSnapshot(
      snapshot: sig.LaunchAtLoginSnapshot(
        enabled: snapshot.enabled,
        isLoading: snapshot.isLoading,
        errorMessage: snapshot.errorMessage,
      ),
    ).sendSignalToRust();
  }

  Future<void> refresh() async {
    final loadingState = state.copyWith(isLoading: true, clearError: true);
    state = loadingState;
    _reportSnapshot(loadingState);
    try {
      final enabled = await _service.isEnabled();
      if (!ref.mounted) return;
      final nextState = LaunchAtLoginState(enabled: enabled, isLoading: false);
      state = nextState;
      _reportSnapshot(nextState);
    } catch (error) {
      if (!ref.mounted) return;
      final nextState = state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
      state = nextState;
      _reportSnapshot(nextState);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (state.isLoading) return;

    final previous = state.enabled;
    final loadingState = state.copyWith(
      enabled: enabled,
      isLoading: true,
      clearError: true,
    );
    state = loadingState;
    _reportSnapshot(loadingState);

    try {
      await _service.setEnabled(enabled);
      final actual = await _service.isEnabled();
      if (!ref.mounted) return;
      final nextState = LaunchAtLoginState(enabled: actual, isLoading: false);
      state = nextState;
      _reportSnapshot(nextState);
    } catch (error) {
      if (!ref.mounted) return;
      final nextState = LaunchAtLoginState(
        enabled: previous,
        isLoading: false,
        errorMessage: error.toString(),
      );
      state = nextState;
      _reportSnapshot(nextState);
    }
  }
}

final launchAtLoginProvider =
    NotifierProvider<LaunchAtLoginNotifier, LaunchAtLoginState>(
      LaunchAtLoginNotifier.new,
    );
