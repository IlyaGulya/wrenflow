import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/update_service.dart';

/// Checks for updates on startup and re-checks every 6 hours.
class UpdateNotifier extends AsyncNotifier<UpdateInfo> {
  static const _checkInterval = Duration(hours: 6);

  Timer? _refreshTimer;

  @override
  Future<UpdateInfo> build() async {
    // Schedule periodic re-checks.
    _refreshTimer = Timer.periodic(_checkInterval, (_) => _refresh());
    ref.onDispose(() {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    });

    return _check();
  }

  Future<UpdateInfo> _check() async {
    final service = UpdateService();
    return service.checkForUpdate();
  }

  /// Re-check for updates and update the state.
  Future<void> _refresh() async {
    state = const AsyncLoading<UpdateInfo>();
    state = AsyncData(await _check());
  }

  /// Manually trigger an update check (e.g. from a "Check for updates" button).
  Future<void> checkNow() async {
    state = const AsyncLoading<UpdateInfo>();
    state = AsyncData(await _check());
  }
}

final updateProvider = AsyncNotifierProvider<UpdateNotifier, UpdateInfo>(
  UpdateNotifier.new,
);
