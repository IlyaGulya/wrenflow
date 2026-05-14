import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';

import '../providers/app_lifecycle_provider.dart';
import '../providers/launch_at_login_provider.dart';
import '../providers/settings_provider.dart';
import '../state/app_lifecycle_state.dart';
import 'main_window_presentation.dart';
import 'shell_pipeline_presentation.dart';
import 'tray_menu_presentation.dart';

/// Manages the macOS system tray (menu bar) icon and context menu.
class SystemTrayManager with TrayListener {
  SystemTrayManager(this._ref);

  final ProviderContainer _ref;
  final _trayManager = TrayManager.instance;

  String? _idleIconPath;
  String? _recordingIconPath;
  String? _transcribingIconPath;

  Future<void> init() async {
    _idleIconPath = await _extractAsset('assets/tray_icons/tray_idle@2x.png');
    _recordingIconPath = await _extractAsset(
      'assets/tray_icons/tray_recording@2x.png',
    );
    _transcribingIconPath = await _extractAsset(
      'assets/tray_icons/tray_transcribing@2x.png',
    );

    if (_idleIconPath != null) {
      await _trayManager.setIcon(
        _idleIconPath!,
        isTemplate: true,
        iconSize: 22,
      );
    }

    _trayManager.addListener(this);

    await _updateContextMenu(_ref.read(trayMenuPresentationProvider));

    _ref.listen<ShellPipelinePresentation>(shellPipelinePresentationProvider, (
      previous,
      next,
    ) {
      _updateIcon(next);
    });

    _ref.listen<TrayMenuPresentation>(trayMenuPresentationProvider, (
      previous,
      next,
    ) {
      _updateContextMenu(next);
    });

    // React to lifecycle changes.
    _ref.listen<AppLifecycleState>(
      appLifecycleProvider,
      (previous, next) => _onLifecycleChanged(next),
    );
  }

  void _onLifecycleChanged(AppLifecycleState next) {
    if (next is! Running) {
      _ref.read(mainWindowNavigationProvider.notifier).close();
    }
    if (next is ShuttingDown) {
      _quit();
    }
  }

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

  Future<void> _updateIcon(ShellPipelinePresentation presentation) async {
    final String? iconPath;
    switch (presentation.trayIcon) {
      case TrayIconVariant.idle:
        iconPath = _idleIconPath;
      case TrayIconVariant.recording:
        iconPath = _recordingIconPath;
      case TrayIconVariant.transcribing:
        iconPath = _transcribingIconPath;
    }

    if (iconPath != null) {
      await _trayManager.setIcon(iconPath, isTemplate: true, iconSize: 22);
    }
  }

  Future<void> _updateContextMenu(TrayMenuPresentation presentation) async {
    final micItems = presentation.microphones
        .map(
          (item) => MenuItem.checkbox(
            label: item.label,
            checked: item.selected,
            onClick: (_) => _selectMicrophone(item.id),
          ),
        )
        .toList();

    final menu = Menu(
      items: [
        MenuItem(
          label: presentation.versionLabel,
          disabled: true,
        ),
        MenuItem(label: presentation.statusText, disabled: true),
        MenuItem.separator(),
        MenuItem.checkbox(
          label: presentation.launchAtLoginLoading
              ? 'Launch at Login...'
              : 'Launch at Login',
          checked: presentation.launchAtLoginEnabled,
          onClick: (_) =>
              _setLaunchAtLogin(!presentation.launchAtLoginEnabled),
        ),
        MenuItem.separator(),
        MenuItem.submenu(
          label: 'Microphone',
          submenu: Menu(items: micItems),
        ),
        MenuItem.separator(),
        MenuItem(label: 'Settings...', onClick: (_) => _showSettings()),
        MenuItem(label: 'History', onClick: (_) => _showHistory()),
        MenuItem.separator(),
        MenuItem(
          label: 'Quit Wrenflow',
          onClick: (_) => _ref.read(appLifecycleProvider.notifier).quit(),
        ),
      ],
    );

    await _trayManager.setContextMenu(menu);
  }

  void _selectMicrophone(String deviceId) {
    _ref.read(settingsProvider.notifier).setSelectedMicrophoneId(deviceId);
    _updateContextMenu(_ref.read(trayMenuPresentationProvider));
  }

  void _setLaunchAtLogin(bool enabled) {
    _ref.read(launchAtLoginProvider.notifier).setEnabled(enabled);
    _updateContextMenu(_ref.read(trayMenuPresentationProvider));
  }

  void _showSettings() {
    if (_ref.read(appLifecycleProvider) is! Running) return;
    _ref
        .read(mainWindowNavigationProvider.notifier)
        .showSettings(SettingsTab.general);
  }

  void _showHistory() {
    if (_ref.read(appLifecycleProvider) is! Running) return;
    _ref
        .read(mainWindowNavigationProvider.notifier)
        .showSettings(SettingsTab.history);
  }

  Future<void> _quit() async {
    await _trayManager.destroy();
    exit(0);
  }

  Future<void> dispose() async {
    _trayManager.removeListener(this);
    await _trayManager.destroy();
  }

  @override
  void onTrayIconMouseUp() {
    _trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseUp() {
    _trayManager.popUpContextMenu();
  }
}
