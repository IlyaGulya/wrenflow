import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/services/permission_service.dart';
import '../src/bindings/signals/signals.dart' as sig;
import 'rust_snapshot_bridge.dart';

/// Presentation-facing permission state.
enum PermissionUiStatus {
  unknown,
  requesting,
  granted,
  denied,
  restricted,
  notApplicable,
}

/// Holds all permission states required by Wrenflow.
class PermissionsState {
  const PermissionsState({
    this.hasSnapshot = false,
    this.microphone = PermissionUiStatus.unknown,
    this.accessibility = PermissionUiStatus.unknown,
  });

  final bool hasSnapshot;
  final PermissionUiStatus microphone;
  final PermissionUiStatus accessibility;

  PermissionsState copyWith({
    bool? hasSnapshot,
    PermissionUiStatus? microphone,
    PermissionUiStatus? accessibility,
  }) {
    return PermissionsState(
      hasSnapshot: hasSnapshot ?? this.hasSnapshot,
      microphone: microphone ?? this.microphone,
      accessibility: accessibility ?? this.accessibility,
    );
  }

  bool get allGranted =>
      microphone == PermissionUiStatus.granted &&
      accessibility == PermissionUiStatus.granted;
}

/// Polls shell permissions, reports them to Rust, and projects the Rust-owned
/// permission snapshot back into Flutter.
class PermissionsNotifier extends RustSnapshotNotifier<PermissionsState> {
  late final PermissionService _permissionService;
  Timer? _pollTimer;

  @override
  PermissionsState build() {
    _permissionService = PermissionService();
    _startRustSnapshotBridge();
    _startPolling();
    ref.onDispose(() => _pollTimer?.cancel());
    return const PermissionsState();
  }

  void _startRustSnapshotBridge() {
    bindRustSnapshotState<sig.PermissionsSnapshotChanged>(
      requestSnapshot: () =>
          const sig.RequestPermissionsSnapshot().sendSignalToRust(),
      signalStream: sig.PermissionsSnapshotChanged.rustSignalStream,
      map: (message) => PermissionsState(
        hasSnapshot: message.hasSnapshot,
        microphone: _fromSignalStatus(message.microphone),
        accessibility: _fromSignalStatus(message.accessibility),
      ),
    );
  }

  void _startPolling() {
    _pollAndReport();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollAndReport(),
    );
  }

  Future<void> _pollAndReport() async {
    try {
      final results = await (
        _permissionService.checkMicrophone(),
        _permissionService.checkAccessibility(),
      ).wait;

      _reportSnapshot(
        microphone: _fromMicrophonePermission(results.$1),
        accessibility: results.$2
            ? PermissionUiStatus.granted
            : PermissionUiStatus.denied,
      );
    } on MissingPluginException {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _reportSnapshot({
    PermissionUiStatus? microphone,
    PermissionUiStatus? accessibility,
  }) {
    sig.ReportPermissionsSnapshot(
      microphone: _toSignalStatus(microphone ?? state.microphone),
      accessibility: _toSignalStatus(accessibility ?? state.accessibility),
    ).sendSignalToRust();
  }

  static PermissionUiStatus _fromMicrophonePermission(
    MicrophonePermission permission,
  ) {
    return switch (permission) {
      MicrophonePermission.granted => PermissionUiStatus.granted,
      MicrophonePermission.denied => PermissionUiStatus.denied,
      MicrophonePermission.notDetermined => PermissionUiStatus.unknown,
    };
  }

  static PermissionUiStatus _fromSignalStatus(sig.PermissionStatus status) {
    return switch (status) {
      sig.PermissionStatus.unknown => PermissionUiStatus.unknown,
      sig.PermissionStatus.requesting => PermissionUiStatus.requesting,
      sig.PermissionStatus.granted => PermissionUiStatus.granted,
      sig.PermissionStatus.denied => PermissionUiStatus.denied,
      sig.PermissionStatus.restricted => PermissionUiStatus.restricted,
      sig.PermissionStatus.notApplicable => PermissionUiStatus.notApplicable,
    };
  }

  static sig.PermissionStatus _toSignalStatus(PermissionUiStatus status) {
    return switch (status) {
      PermissionUiStatus.unknown => sig.PermissionStatus.unknown,
      PermissionUiStatus.requesting => sig.PermissionStatus.requesting,
      PermissionUiStatus.granted => sig.PermissionStatus.granted,
      PermissionUiStatus.denied => sig.PermissionStatus.denied,
      PermissionUiStatus.restricted => sig.PermissionStatus.restricted,
      PermissionUiStatus.notApplicable => sig.PermissionStatus.notApplicable,
    };
  }

  Future<void> requestMicrophone() async {
    _reportSnapshot(microphone: PermissionUiStatus.requesting);
    await _permissionService.requestMicrophone();
    await refreshPermissions();
  }

  Future<void> requestAccessibility() async {
    _reportSnapshot(accessibility: PermissionUiStatus.requesting);
    await _permissionService.requestAccessibility();
    await refreshPermissions();
  }

  Future<void> openAccessibilitySettings() =>
      _permissionService.openAccessibilitySettings();

  Future<void> openMicrophoneSettings() =>
      _permissionService.openMicrophoneSettings();

  Future<void> refreshPermissions() => _pollAndReport();
}

final permissionsProvider =
    NotifierProvider<PermissionsNotifier, PermissionsState>(
      PermissionsNotifier.new,
    );
