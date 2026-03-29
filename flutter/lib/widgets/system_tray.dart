import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:wrenflow/providers/app_lifecycle_provider.dart';
import 'package:wrenflow/providers/pipeline_state_provider.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';
import 'package:wrenflow/state/app_lifecycle_state.dart';

/// Manages the macOS system tray (menu bar) icon and context menu.
class SystemTrayManager {
  SystemTrayManager(this._ref);

  final ProviderContainer _ref;
  final _trayManager = TrayManager.instance;

  String? _idleIconPath;
  String? _recordingIconPath;
  String? _transcribingIconPath;

  WindowController? _settingsWindow;
  WindowController? _historyWindow;

  Future<void> init() async {
    _idleIconPath = await _extractAsset('assets/tray_icons/tray_idle.png');
    _recordingIconPath =
        await _extractAsset('assets/tray_icons/tray_recording.png');
    _transcribingIconPath =
        await _extractAsset('assets/tray_icons/tray_transcribing.png');

    if (_idleIconPath != null) {
      await _trayManager.setIcon(_idleIconPath!);
    }

    await _updateContextMenu(const PipelineStateIdle());

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

  Future<void> _closeSubWindows() async {
    if (_settingsWindow != null) {
      try {
        await _settingsWindow!.hide();
      } catch (_) {}
      _settingsWindow = null;
    }
    if (_historyWindow != null) {
      try {
        await _historyWindow!.hide();
      } catch (_) {}
      _historyWindow = null;
    }
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

  Future<void> _showSettings() async {
    // Only open during Running state.
    if (_ref.read(appLifecycleProvider) is! Running) return;

    if (_settingsWindow != null) {
      try {
        await _settingsWindow!.show();
        return;
      } catch (_) {
        _settingsWindow = null;
      }
    }

    _settingsWindow = await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({'type': 'settings'}),
        hiddenAtLaunch: false,
        width: 720,
        height: 520,
        titleBarHidden: true,
      ),
    );
  }

  Future<void> _showHistory() async {
    if (_ref.read(appLifecycleProvider) is! Running) return;

    if (_historyWindow != null) {
      try {
        await _historyWindow!.show();
        return;
      } catch (_) {
        _historyWindow = null;
      }
    }

    _historyWindow = await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({'type': 'history'}),
        hiddenAtLaunch: false,
        width: 400,
        height: 500,
        titleBarHidden: true,
      ),
    );
  }

  Future<void> _quit() async {
    await _trayManager.destroy();
    exit(0);
  }

  Future<void> dispose() async {
    await _trayManager.destroy();
  }
}
