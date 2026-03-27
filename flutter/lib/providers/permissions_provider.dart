import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  bool get allGranted =>
      microphone == PermissionStatus.granted &&
      accessibility == PermissionStatus.granted;
}

/// Manages permission states. This is a placeholder that will be wired to
/// platform channels later to query actual macOS permissions.
class PermissionsNotifier extends Notifier<PermissionsState> {
  @override
  PermissionsState build() {
    return const PermissionsState();
  }

  /// Update microphone permission status.
  void setMicrophonePermission(PermissionStatus status) {
    state = state.copyWith(microphone: status);
  }

  /// Update accessibility permission status.
  void setAccessibilityPermission(PermissionStatus status) {
    state = state.copyWith(accessibility: status);
  }

  /// Refresh all permissions from the platform.
  /// Placeholder: will be wired to platform channels later.
  Future<void> refreshPermissions() async {
    // TODO: call platform channel to query actual macOS permission status
  }
}

final permissionsProvider =
    NotifierProvider<PermissionsNotifier, PermissionsState>(
  PermissionsNotifier.new,
);
