import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lifecycle_provider.dart';
import '../state/app_lifecycle_state.dart';

enum SettingsTab { general, models, history, about }

enum MainWindowSurface { hidden, settings }

@immutable
class MainWindowNavigationState {
  const MainWindowNavigationState.hidden({
    this.settingsTab = SettingsTab.general,
  }) : surface = MainWindowSurface.hidden;

  const MainWindowNavigationState.settings({
    this.settingsTab = SettingsTab.general,
  }) : surface = MainWindowSurface.settings;

  final MainWindowSurface surface;
  final SettingsTab settingsTab;

  bool get showsSettings => surface == MainWindowSurface.settings;
}

class MainWindowNavigationNotifier extends Notifier<MainWindowNavigationState> {
  @override
  MainWindowNavigationState build() => const MainWindowNavigationState.hidden();

  void showSettings(SettingsTab tab) {
    state = MainWindowNavigationState.settings(settingsTab: tab);
  }

  void close() {
    state = MainWindowNavigationState.hidden(settingsTab: state.settingsTab);
  }
}

final mainWindowNavigationProvider =
    NotifierProvider<MainWindowNavigationNotifier, MainWindowNavigationState>(
      MainWindowNavigationNotifier.new,
    );

enum MainWindowContent { splash, onboarding, permissionRecovery, settings, blank }

@immutable
class MainWindowPresentation {
  const MainWindowPresentation({
    required this.visible,
    required this.skipTaskbar,
    required this.content,
    this.settingsTab = SettingsTab.general,
    this.width = 340,
    this.height = 380,
  });

  final bool visible;
  final bool skipTaskbar;
  final MainWindowContent content;
  final SettingsTab settingsTab;
  final double width;
  final double height;
}

final mainWindowPresentationProvider = Provider<MainWindowPresentation>((ref) {
  final lifecycle = ref.watch(appLifecycleProvider);
  final navigation = ref.watch(mainWindowNavigationProvider);

  return switch (lifecycle) {
    Initializing() => const MainWindowPresentation(
      visible: false,
      skipTaskbar: true,
      content: MainWindowContent.splash,
    ),
    Onboarding() => const MainWindowPresentation(
      visible: true,
      skipTaskbar: false,
      content: MainWindowContent.onboarding,
    ),
    PermissionRecovery() => const MainWindowPresentation(
      visible: true,
      skipTaskbar: false,
      content: MainWindowContent.permissionRecovery,
    ),
    Running() => navigation.showsSettings
        ? MainWindowPresentation(
            visible: true,
            skipTaskbar: false,
            content: MainWindowContent.settings,
            settingsTab: navigation.settingsTab,
            width: 720,
            height: 520,
          )
        : const MainWindowPresentation(
            visible: false,
            skipTaskbar: true,
            content: MainWindowContent.blank,
          ),
    ShuttingDown() => const MainWindowPresentation(
      visible: false,
      skipTaskbar: true,
      content: MainWindowContent.blank,
    ),
  };
});
