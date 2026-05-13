import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/launch_at_login_service.dart';

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

  @override
  LaunchAtLoginState build() {
    unawaited(refresh());
    return const LaunchAtLoginState.initial();
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final enabled = await _service.isEnabled();
      if (!ref.mounted) return;
      state = LaunchAtLoginState(enabled: enabled, isLoading: false);
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (state.isLoading) return;

    final previous = state.enabled;
    state = state.copyWith(enabled: enabled, isLoading: true, clearError: true);

    try {
      await _service.setEnabled(enabled);
      final actual = await _service.isEnabled();
      if (!ref.mounted) return;
      state = LaunchAtLoginState(enabled: actual, isLoading: false);
    } catch (error) {
      if (!ref.mounted) return;
      state = LaunchAtLoginState(
        enabled: previous,
        isLoading: false,
        errorMessage: error.toString(),
      );
    }
  }
}

final launchAtLoginProvider =
    NotifierProvider<LaunchAtLoginNotifier, LaunchAtLoginState>(
      LaunchAtLoginNotifier.new,
    );
