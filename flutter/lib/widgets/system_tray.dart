import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rinf/rinf.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:wrenflow/providers/app_lifecycle_provider.dart';
import 'package:wrenflow/providers/pipeline_state_provider.dart';
import 'package:wrenflow/providers/settings_provider.dart';
import 'package:wrenflow/screens/settings_screen.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';
import 'package:wrenflow/state/app_lifecycle_state.dart';

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
  StreamSubscription<RustSignalPack<AudioDevicesListed>>? _deviceSub;

  Future<void> init() async {
    _idleIconPath = await _extractAsset('assets/tray_icons/tray_idle@2x.png');
    _recordingIconPath =
        await _extractAsset('assets/tray_icons/tray_recording@2x.png');
    _transcribingIconPath =
        await _extractAsset('assets/tray_icons/tray_transcribing@2x.png');

    if (_idleIconPath != null) {
      await _trayManager.setIcon(_idleIconPath!, isTemplate: true, iconSize: 22);
    }

    _trayManager.addListener(this);

    // Listen for audio device list updates.
    _deviceSub = AudioDevicesListed.rustSignalStream.listen((signal) {
      _audioDevices = signal.message.devices;
      _defaultDeviceName = signal.message.defaultDeviceName;
      // Rebuild menu with updated device list.
      final lastState = _ref.read(pipelineStateProvider).value;
      _updateContextMenu(lastState ?? const PipelineStateIdle());
    });

    // Request initial device list.
    const ListAudioDevices().sendSignalToRust();

    await _updateContextMenu(const PipelineStateIdle());

    // React to pipeline state changes (icon + menu).
    _ref.listen<AsyncValue<PipelineState>>(
      pipelineStateProvider,
      (previous, next) {
        final state = next.value;
        if (state != null) _onPipelineStateChanged(state);
      },
    );

    // React to lifecycle changes.
    _ref.listen<AppLifecycleState>(
      appLifecycleProvider,
      (previous, next) => _onLifecycleChanged(next),
    );
  }

  // ── Lifecycle reactions ───────────────────────────────────

  void _onLifecycleChanged(AppLifecycleState next) {
    if (next is! Running) {
      _ref.read(activeScreenProvider.notifier).close();
    }
    if (next is ShuttingDown) {
      _quit();
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
      await _trayManager.setIcon(iconPath, isTemplate: true, iconSize: 22);
    }
  }

  Future<void> _updateContextMenu(PipelineState state) async {
    final statusText = _statusText(state);
    final settings = _ref.read(settingsProvider);
    final selectedMicId = settings.selectedMicrophoneId;

    // Build microphone submenu.
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
        MenuItem(label: 'Wrenflow v1.0.0', disabled: true),
        MenuItem(label: statusText, disabled: true),
        MenuItem.separator(),
        MenuItem.submenu(
          label: 'Microphone',
          submenu: Menu(items: micItems),
        ),
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

  // ── Microphone selection ──────────────────────────────────

  void _selectMicrophone(String deviceId) {
    _ref.read(settingsProvider.notifier).setSelectedMicrophoneId(deviceId);
    // Refresh menu to update checkmarks.
    final lastState = _ref.read(pipelineStateProvider).value;
    _updateContextMenu(lastState ?? const PipelineStateIdle());
  }

  // ── Screen management (single window) ───────────────────

  void _showSettings() {
    if (_ref.read(appLifecycleProvider) is! Running) return;
    _ref.read(settingsInitialTabProvider.notifier).set(SettingsTab.general);
    _ref.read(activeScreenProvider.notifier).show(ActiveScreen.settings);
  }

  void _showHistory() {
    if (_ref.read(appLifecycleProvider) is! Running) return;
    _ref.read(settingsInitialTabProvider.notifier).set(SettingsTab.history);
    _ref.read(activeScreenProvider.notifier).show(ActiveScreen.settings);
  }

  Future<void> _quit() async {
    await _trayManager.destroy();
    exit(0);
  }

  Future<void> dispose() async {
    _deviceSub?.cancel();
    _trayManager.removeListener(this);
    await _trayManager.destroy();
  }

  // ── TrayListener ────────────────────────────────────────────

  @override
  void onTrayIconMouseUp() {
    // Refresh device list before showing menu.
    const ListAudioDevices().sendSignalToRust();
    _trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseUp() {
    const ListAudioDevices().sendSignalToRust();
    _trayManager.popUpContextMenu();
  }
}
