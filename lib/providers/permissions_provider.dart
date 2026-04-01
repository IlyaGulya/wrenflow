import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/permission_service.dart';

/// Represents the state of a single macOS permission.
enum PermissionStatus {
  unknown,
  granted,
  denied,
  restricted,
}

/// Holds all permission states required by Wrenflow.
class PermissionsState {
  const PermissionsState({
    this.microphone = PermissionStatus.unknown,
    this.accessibility = PermissionStatus.unknown,
  });

  final PermissionStatus microphone;
  final PermissionStatus accessibility;

  PermissionsState copyWith({
    PermissionStatus? microphone,
    PermissionStatus? accessibility,
  }) {
    return PermissionsState(
      microphone: microphone ?? this.microphone,
      accessibility: accessibility ?? this.accessibility,
    );
  }

  /// Whether all required permissions are granted.
  bool get allGranted =>
      microphone == PermissionStatus.granted &&
      accessibility == PermissionStatus.granted;
}

/// Manages permission states by polling the platform at 1 Hz.
class PermissionsNotifier extends Notifier<PermissionsState> {
  late final PermissionService _permissionService;
  Timer? _pollTimer;

  @override
  PermissionsState build() {
    _permissionService = PermissionService();

    // Start polling immediately.
    _startPolling();

    // Cancel the timer when this notifier is disposed.
    ref.onDispose(_stopPolling);

    return const PermissionsState();
  }

  void _startPolling() {
    // Fire one poll immediately so the UI doesn't wait a full second.
    _poll();

    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    try {
      final results = await (
        _permissionService.checkMicrophone(),
        _permissionService.checkAccessibility(),
      ).wait;

      final micStatus = _mapMicrophonePermission(results.$1);
      final accStatus =
          results.$2 ? PermissionStatus.granted : PermissionStatus.denied;

      // Only update state if something actually changed.
      if (state.microphone != micStatus || state.accessibility != accStatus) {
        state = state.copyWith(
          microphone: micStatus,
          accessibility: accStatus,
        );
      }
    } on MissingPluginException {
      // Platform channel not available (e.g. running on a non-macOS host or
      // in tests without a mock). Stop polling to avoid log spam.
      _stopPolling();
    }
  }

  /// Map the service-level enum to the provider-level enum.
  static PermissionStatus _mapMicrophonePermission(MicrophonePermission perm) {
    switch (perm) {
      case MicrophonePermission.granted:
        return PermissionStatus.granted;
      case MicrophonePermission.denied:
        return PermissionStatus.denied;
      case MicrophonePermission.notDetermined:
        return PermissionStatus.unknown;
    }
  }

  /// Convenience: expose microphone status as a string label.
  String get microphoneStatus => state.microphone.name;

  /// Convenience: expose accessibility status as a bool.
  bool get accessibilityStatus => state.accessibility == PermissionStatus.granted;

  /// Convenience: whether every required permission is granted.
  bool get allRequiredGranted => state.allGranted;

  /// Update microphone permission status.
  void setMicrophonePermission(PermissionStatus status) {
    state = state.copyWith(microphone: status);
  }

  /// Update accessibility permission status.
  void setAccessibilityPermission(PermissionStatus status) {
    state = state.copyWith(accessibility: status);
  }

  /// Refresh all permissions from the platform (on-demand).
  Future<void> refreshPermissions() async {
    await _poll();
  }
}

final permissionsProvider =
    NotifierProvider<PermissionsNotifier, PermissionsState>(
  PermissionsNotifier.new,
);
