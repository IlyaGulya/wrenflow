import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/launch_at_login_shell.dart';
import '../src/bindings/signals/signals.dart' as sig;
import 'rust_snapshot_bridge.dart';

@immutable
class LaunchAtLoginState {
  const LaunchAtLoginState({
    required this.isAvailable,
    required this.enabled,
    required this.isLoading,
    this.unavailableReason,
    this.errorMessage,
  });

  const LaunchAtLoginState.initial()
    : isAvailable = true,
      enabled = false,
      isLoading = true,
      unavailableReason = null,
      errorMessage = null;

  final bool isAvailable;
  final bool enabled;
  final bool isLoading;
  final String? unavailableReason;
  final String? errorMessage;

  LaunchAtLoginState copyWith({
    bool? isAvailable,
    bool? enabled,
    bool? isLoading,
    String? unavailableReason,
    String? errorMessage,
    bool clearUnavailableReason = false,
    bool clearError = false,
  }) {
    return LaunchAtLoginState(
      isAvailable: isAvailable ?? this.isAvailable,
      enabled: enabled ?? this.enabled,
      isLoading: isLoading ?? this.isLoading,
      unavailableReason: clearUnavailableReason
          ? null
          : unavailableReason ?? this.unavailableReason,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class LaunchAtLoginNotifier extends RustSnapshotNotifier<LaunchAtLoginState> {
  final _shell = platformLaunchAtLoginShell;

  @override
  LaunchAtLoginState build() {
    bindRustSnapshotState<sig.LaunchAtLoginSnapshotChanged>(
      requestSnapshot: () =>
          const sig.RequestLaunchAtLoginSnapshot().sendSignalToRust(),
      signalStream: sig.LaunchAtLoginSnapshotChanged.rustSignalStream,
      map: (message) {
        final snapshot = message.snapshot;
        return LaunchAtLoginState(
          isAvailable: snapshot.isAvailable,
          enabled: snapshot.enabled,
          isLoading: snapshot.isLoading,
          unavailableReason: snapshot.unavailableReason,
          errorMessage: snapshot.errorMessage,
        );
      },
    );
    return const LaunchAtLoginState.initial();
  }

  void _reportSnapshot(LaunchAtLoginState snapshot) {
    sig.ReportLaunchAtLoginSnapshot(
      snapshot: sig.LaunchAtLoginSnapshot(
        isAvailable: snapshot.isAvailable,
        enabled: snapshot.enabled,
        isLoading: snapshot.isLoading,
        unavailableReason: snapshot.unavailableReason,
        errorMessage: snapshot.errorMessage,
      ),
    ).sendSignalToRust();
  }

  Future<void> refresh() async {
    final loadingState = state.copyWith(
      isLoading: true,
      clearError: true,
      clearUnavailableReason: true,
    );
    state = loadingState;
    _reportSnapshot(loadingState);
    try {
      final isAvailable = await _shell.isFeatureAvailable();
      final unavailableReason = isAvailable
          ? null
          : await _shell.unsupportedReason();
      if (!isAvailable) {
        if (!ref.mounted) return;
        final nextState = LaunchAtLoginState(
          isAvailable: false,
          enabled: false,
          isLoading: false,
          unavailableReason: unavailableReason,
        );
        state = nextState;
        _reportSnapshot(nextState);
        return;
      }

      final enabled = await _shell.isEnabled();
      if (!ref.mounted) return;
      final nextState = LaunchAtLoginState(
        isAvailable: true,
        enabled: enabled,
        isLoading: false,
      );
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
    if (state.isLoading || !state.isAvailable) return;

    final previous = state.enabled;
    final loadingState = state.copyWith(
      enabled: enabled,
      isLoading: true,
      clearError: true,
      clearUnavailableReason: true,
    );
    state = loadingState;
    _reportSnapshot(loadingState);

    try {
      await _shell.setEnabled(enabled);
      final actual = await _shell.isEnabled();
      if (!ref.mounted) return;
      final nextState = LaunchAtLoginState(
        isAvailable: true,
        enabled: actual,
        isLoading: false,
      );
      state = nextState;
      _reportSnapshot(nextState);
    } catch (error) {
      if (!ref.mounted) return;
      final nextState = LaunchAtLoginState(
        isAvailable: state.isAvailable,
        enabled: previous,
        isLoading: false,
        unavailableReason: state.unavailableReason,
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
