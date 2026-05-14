import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';

import '../providers/app_lifecycle_provider.dart';
import '../providers/audio_devices_provider.dart';
import '../providers/launch_at_login_provider.dart';
import '../providers/settings_provider.dart';
import '../services/app_version.dart';
import '../src/bindings/signals/signals.dart';
import '../state/app_lifecycle_state.dart';
import 'main_window_presentation.dart';
import 'shell_pipeline_presentation.dart';

/// Manages the macOS system tray (menu bar) icon and context menu.
class SystemTrayManager with TrayListener {
  SystemTrayManager(this._ref);

  final ProviderContainer _ref;
  final _trayManager = TrayManager.instance;

  String? _idleIconPath;
  String? _recordingIconPath;
  String? _transcribingIconPath;

  List<AudioDeviceInfo> _audioDevices = [];
  String _defaultDeviceName = '';

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

    _ref.listen<AsyncValue<AudioDevicesSnapshotView>>(
      audioDevicesSnapshotProvider,
      (previous, next) {
        final snapshot = next.value;
        if (snapshot == null) return;
        _audioDevices = snapshot.devices;
        _defaultDeviceName = snapshot.defaultDeviceName;
        _updateContextMenu(_ref.read(shellPipelinePresentationProvider));
      },
    );

    await _updateContextMenu(_ref.read(shellPipelinePresentationProvider));

    _ref.listen<ShellPipelinePresentation>(shellPipelinePresentationProvider, (
      previous,
      next,
    ) {
      _onPipelinePresentationChanged(next);
    });

    // React to lifecycle changes.
    _ref.listen<AppLifecycleState>(
      appLifecycleProvider,
      (previous, next) => _onLifecycleChanged(next),
    );

    _ref.listen<LaunchAtLoginState>(launchAtLoginProvider, (previous, next) {
      _updateContextMenu(_ref.read(shellPipelinePresentationProvider));
    });
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

  void _onPipelinePresentationChanged(ShellPipelinePresentation presentation) {
    _updateIcon(presentation);
    _updateContextMenu(presentation);
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

  Future<void> _updateContextMenu(ShellPipelinePresentation presentation) async {
    final audioSnapshot = _ref.read(audioDevicesSnapshotProvider).value;
    final selectedMicId =
        audioSnapshot?.effectiveSelectedDeviceId ??
        _ref.read(settingsProvider).selectedMicrophoneId;
    final launchAtLogin = _ref.read(launchAtLoginProvider);

    final defaultLabel = _defaultDeviceName.isNotEmpty
        ? 'System Default ($_defaultDeviceName)'
        : 'System Default';

    final micItems = <MenuItem>[
      MenuItem.checkbox(
        label: defaultLabel,
        checked: selectedMicId == 'default',
        onClick: (_) => _selectMicrophone('default'),
      ),
      for (final device in _audioDevices)
        MenuItem.checkbox(
          label: device.name,
          checked: selectedMicId == device.id,
          onClick: (_) => _selectMicrophone(device.id),
        ),
    ];

    final menu = Menu(
      items: [
        MenuItem(
          label: 'Wrenflow v${AppVersion.displayVersion}',
          disabled: true,
        ),
        MenuItem(label: presentation.statusText, disabled: true),
        MenuItem.separator(),
        MenuItem.checkbox(
          label: launchAtLogin.isLoading
              ? 'Launch at Login...'
              : 'Launch at Login',
          checked: launchAtLogin.enabled,
          onClick: (_) => _setLaunchAtLogin(!launchAtLogin.enabled),
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
    _updateContextMenu(_ref.read(shellPipelinePresentationProvider));
  }

  void _setLaunchAtLogin(bool enabled) {
    _ref.read(launchAtLoginProvider.notifier).setEnabled(enabled);
    _updateContextMenu(_ref.read(shellPipelinePresentationProvider));
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
