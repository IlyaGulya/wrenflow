import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lifecycle_provider.dart';
import '../providers/launch_at_login_provider.dart';
import '../providers/settings_provider.dart';
import '../state/app_lifecycle_state.dart';
import 'main_window_presentation.dart';
import 'shell_pipeline_presentation.dart';
import 'tray_shell.dart';
import 'tray_menu_presentation.dart';

/// Manages the macOS system tray (menu bar) icon and context menu.
class SystemTrayManager implements TrayShellListener {
  SystemTrayManager(this._ref);

  final ProviderContainer _ref;
  final _trayShell = platformTrayShell;

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
      await _trayShell.setIcon(_idleIconPath!);
    }

    _trayShell.addListener(this);

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
      await _trayShell.setIcon(iconPath);
    }
  }

  Future<void> _updateContextMenu(TrayMenuPresentation presentation) async {
    final micItems = presentation.microphoneSelectionAvailable
        ? presentation.microphones
              .map(
                (item) => TrayMenuCheckboxItem(
                  label: item.label,
                  checked: item.selected,
                  onTap: () => _selectMicrophone(item.id),
                ),
              )
              .toList()
        : <TrayMenuEntry>[
            TrayMenuLabelItem(
              label: presentation.microphoneHint ?? 'Microphone selection unavailable',
              disabled: true,
            ),
          ];

    final menu = TrayMenuModel(
      items: [
        TrayMenuLabelItem(
          label: presentation.versionLabel,
          disabled: true,
        ),
        TrayMenuLabelItem(label: presentation.statusText, disabled: true),
        const TrayMenuSeparator(),
        if (presentation.showLaunchAtLogin) ...[
          TrayMenuCheckboxItem(
            label: presentation.launchAtLoginLoading
                ? 'Launch at Login...'
                : 'Launch at Login',
            checked: presentation.launchAtLoginEnabled,
            onTap: () => _setLaunchAtLogin(!presentation.launchAtLoginEnabled),
          ),
          const TrayMenuSeparator(),
        ],
        TrayMenuSubmenuItem(
          label: 'Microphone',
          children: micItems,
        ),
        const TrayMenuSeparator(),
        TrayMenuLabelItem(
          label: presentation.settingsLabel,
          disabled: !presentation.settingsEnabled,
          onTap: _showSettings,
        ),
        if (presentation.showHistory)
          TrayMenuLabelItem(label: 'History', onTap: _showHistory),
        const TrayMenuSeparator(),
        TrayMenuLabelItem(
          label: 'Quit Wrenflow',
          onTap: () => _ref.read(appLifecycleProvider.notifier).quit(),
        ),
      ],
    );

    await _trayShell.setContextMenu(menu);
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
    await _trayShell.destroy();
    exit(0);
  }

  Future<void> dispose() async {
    _trayShell.removeListener(this);
    await _trayShell.destroy();
  }

  @override
  void onPrimaryClick() {
    _trayShell.popUpContextMenu();
  }

  @override
  void onSecondaryClick() {
    _trayShell.popUpContextMenu();
  }
}
