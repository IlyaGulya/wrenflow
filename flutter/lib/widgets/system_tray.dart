import 'dart:convert';
import 'dart:io';

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:wrenflow/providers/app_lifecycle_provider.dart';
import 'package:wrenflow/providers/pipeline_state_provider.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';
import 'package:wrenflow/state/app_lifecycle_state.dart';

/// Whether any sub-windows (settings, history) are currently open.
class SubWindowNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final hasOpenSubWindowsProvider =
    NotifierProvider<SubWindowNotifier, bool>(SubWindowNotifier.new);

/// Manages the macOS system tray (menu bar) icon and context menu.
class SystemTrayManager with TrayListener {
  SystemTrayManager(this._ref);

  final ProviderContainer _ref;
  final _trayManager = TrayManager.instance;

  String? _idleIconPath;
  String? _recordingIconPath;
  String? _transcribingIconPath;

  WindowController? _settingsWindow;
  WindowController? _historyWindow;
  StreamSubscription<void>? _windowsChangedSub;

  Future<void> init() async {
    _idleIconPath = await _extractAsset('assets/tray_icons/tray_idle.png');
    _recordingIconPath =
        await _extractAsset('assets/tray_icons/tray_recording.png');
    _transcribingIconPath =
        await _extractAsset('assets/tray_icons/tray_transcribing.png');

    if (_idleIconPath != null) {
      await _trayManager.setIcon(_idleIconPath!);
    }

    _trayManager.addListener(this);

    await _updateContextMenu(const PipelineStateIdle());

    // Track sub-window close events.
    _windowsChangedSub = onWindowsChanged.listen((_) => _syncSubWindowState());

    // Sub-windows created lazily on first open, then reused via hide/show.

    // React to pipeline state changes (icon + menu).
    _ref.listen<AsyncValue<PipelineState>>(
      pipelineStateProvider,
      (previous, next) {
        final state = next.value;
        if (state != null) _onPipelineStateChanged(state);
      },
    );

    // React to lifecycle changes (close sub-windows when leaving Running).
    _ref.listen<AppLifecycleState>(
      appLifecycleProvider,
      (previous, next) => _onLifecycleChanged(next),
    );
  }

  // ── Lifecycle reactions ───────────────────────────────────

  void _onLifecycleChanged(AppLifecycleState next) {
    if (next is! Running) {
      _closeSubWindows();
    }
    if (next is ShuttingDown) {
      _quit();
    }
  }

  Future<void> _syncSubWindowState() async {
    final allWindows = await WindowController.getAll();
    // Main window is always in the list; sub-windows are extra.
    final hasSubWindows = allWindows.length > 1;
    final current = _ref.read(hasOpenSubWindowsProvider);
    if (current != hasSubWindows) {
      _ref.read(hasOpenSubWindowsProvider.notifier).set(hasSubWindows);
    }
    // Clean up stale references.
    if (!hasSubWindows) {
      _settingsWindow = null;
      _historyWindow = null;
    }
  }

  Future<void> _closeSubWindows() async {
    if (_settingsWindow != null) {
      try { await _settingsWindow!.hide(); } catch (_) {}
    }
    if (_historyWindow != null) {
      try { await _historyWindow!.hide(); } catch (_) {}
    }
    _ref.read(hasOpenSubWindowsProvider.notifier).set(false);
  }

  // ── Pipeline reactions ────────────────────────────────────

  Future<String?> _extractAsset(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      final fileName = assetPath.split('/').last;
      final tempDir = Directory.systemTemp;
      final file = File('${tempDir.path}/wrenflow_$fileName');
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (e) {
      return null;
    }
  }

  void _onPipelineStateChanged(PipelineState state) {
    _updateIcon(state);
    _updateContextMenu(state);
  }

  Future<void> _updateIcon(PipelineState state) async {
    final String? iconPath;
    if (state is PipelineStateRecording) {
      iconPath = _recordingIconPath;
    } else if (state is PipelineStateTranscribing) {
      iconPath = _transcribingIconPath;
    } else {
      iconPath = _idleIconPath;
    }

    if (iconPath != null) {
      await _trayManager.setIcon(iconPath);
    }
  }

  Future<void> _updateContextMenu(PipelineState state) async {
    final statusText = _statusText(state);

    final menu = Menu(
      items: [
        MenuItem(label: statusText, disabled: true),
        MenuItem.separator(),
        MenuItem(
          label: 'Settings...',
          onClick: (_) => _showSettings(),
        ),
        MenuItem(
          label: 'History',
          onClick: (_) => _showHistory(),
        ),
        MenuItem.separator(),
        MenuItem(
          label: 'Quit Wrenflow',
          onClick: (_) =>
              _ref.read(appLifecycleProvider.notifier).quit(),
        ),
      ],
    );

    await _trayManager.setContextMenu(menu);
  }

  String _statusText(PipelineState state) {
    if (state is PipelineStateIdle) return 'Ready';
    if (state is PipelineStateStarting) return 'Starting...';
    if (state is PipelineStateInitializing) return 'Initializing...';
    if (state is PipelineStateRecording) return 'Recording...';
    if (state is PipelineStateTranscribing) return 'Transcribing...';
    if (state is PipelineStatePasting) return 'Pasting...';
    if (state is PipelineStateError) return 'Error';
    return 'Ready';
  }

  // ── Sub-window management ─────────────────────────────────

  void _log(String msg) {
    final f = File('/tmp/wrenflow_dart.log');
    f.writeAsStringSync('${DateTime.now()} $msg\n', mode: FileMode.append);
  }

  Future<void> _showSettings() async {
    if (_ref.read(appLifecycleProvider) is! Running) return;
    try {
      _settingsWindow = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'type': 'settings'}),
          hiddenAtLaunch: false,
          width: 720,
          height: 520,
          titleBarHidden: true,
        ),
      );
      _ref.read(hasOpenSubWindowsProvider.notifier).set(true);
    } catch (e, st) {
      _log('_showSettings error: $e\n$st');
      _settingsWindow = null;
    }
  }

  Future<void> _showHistory() async {
    if (_ref.read(appLifecycleProvider) is! Running) return;
    try {
      _historyWindow = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'type': 'history'}),
          hiddenAtLaunch: false,
          width: 400,
          height: 500,
          titleBarHidden: true,
        ),
      );
      _ref.read(hasOpenSubWindowsProvider.notifier).set(true);
    } catch (e, st) {
      _log('_showHistory error: $e\n$st');
      _historyWindow = null;
    }
  }

  Future<void> _quit() async {
    await _trayManager.destroy();
    exit(0);
  }

  Future<void> dispose() async {
    _windowsChangedSub?.cancel();
    _trayManager.removeListener(this);
    await _trayManager.destroy();
  }

  // ── TrayListener ────────────────────────────────────────────

  @override
  void onTrayIconMouseUp() {
    _trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseUp() {
    _trayManager.popUpContextMenu();
  }
}
