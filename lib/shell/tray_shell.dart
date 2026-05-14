import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

abstract class TrayShellListener {
  void onPrimaryClick();
  void onSecondaryClick();
}

sealed class TrayMenuEntry {
  const TrayMenuEntry();
}

class TrayMenuLabelItem extends TrayMenuEntry {
  const TrayMenuLabelItem({
    required this.label,
    this.disabled = false,
    this.onTap,
  });

  final String label;
  final bool disabled;
  final VoidCallback? onTap;
}

class TrayMenuCheckboxItem extends TrayMenuEntry {
  const TrayMenuCheckboxItem({
    required this.label,
    required this.checked,
    this.onTap,
  });

  final String label;
  final bool checked;
  final VoidCallback? onTap;
}

class TrayMenuSubmenuItem extends TrayMenuEntry {
  const TrayMenuSubmenuItem({
    required this.label,
    required this.children,
  });

  final String label;
  final List<TrayMenuEntry> children;
}

class TrayMenuSeparator extends TrayMenuEntry {
  const TrayMenuSeparator();
}

class TrayMenuModel {
  const TrayMenuModel({required this.items});

  final List<TrayMenuEntry> items;
}

abstract class TrayShell {
  void addListener(TrayShellListener listener);
  void removeListener(TrayShellListener listener);
  Future<void> setIcon(String path);
  Future<void> setContextMenu(TrayMenuModel menu);
  Future<void> destroy();
  void popUpContextMenu();
}

final TrayShell _platformTrayShell =
    defaultTargetPlatform == TargetPlatform.macOS
    ? _MacOsTrayShell()
    : const _UnsupportedTrayShell();

TrayShell get platformTrayShell => _platformTrayShell;

class _MacOsTrayShell with TrayListener implements TrayShell {
  final _trayManager = TrayManager.instance;
  TrayShellListener? _listener;
  bool _registered = false;

  @override
  void addListener(TrayShellListener listener) {
    _listener = listener;
    if (!_registered) {
      _trayManager.addListener(this);
      _registered = true;
    }
  }

  @override
  void removeListener(TrayShellListener listener) {
    if (identical(_listener, listener)) {
      _listener = null;
    }
    if (_registered) {
      _trayManager.removeListener(this);
      _registered = false;
    }
  }

  @override
  Future<void> setIcon(String path) async {
    await _trayManager.setIcon(path, isTemplate: true, iconSize: 22);
  }

  @override
  Future<void> setContextMenu(TrayMenuModel menu) async {
    await _trayManager.setContextMenu(_toMenu(menu));
  }

  @override
  Future<void> destroy() async {
    if (_registered) {
      _trayManager.removeListener(this);
      _registered = false;
    }
    _listener = null;
    await _trayManager.destroy();
  }

  @override
  void popUpContextMenu() {
    _trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconMouseUp() {
    _listener?.onPrimaryClick();
  }

  @override
  void onTrayIconRightMouseUp() {
    _listener?.onSecondaryClick();
  }

  Menu _toMenu(TrayMenuModel menu) {
    return Menu(items: menu.items.map(_toMenuItem).toList());
  }

  MenuItem _toMenuItem(TrayMenuEntry entry) {
    return switch (entry) {
      TrayMenuLabelItem() => MenuItem(
        label: entry.label,
        disabled: entry.disabled,
        onClick: entry.onTap == null ? null : (_) => entry.onTap!(),
      ),
      TrayMenuCheckboxItem() => MenuItem.checkbox(
        label: entry.label,
        checked: entry.checked,
        onClick: entry.onTap == null ? null : (_) => entry.onTap!(),
      ),
      TrayMenuSubmenuItem() => MenuItem.submenu(
        label: entry.label,
        submenu: Menu(items: entry.children.map(_toMenuItem).toList()),
      ),
      TrayMenuSeparator() => MenuItem.separator(),
    };
  }
}

class _UnsupportedTrayShell implements TrayShell {
  const _UnsupportedTrayShell();

  @override
  void addListener(TrayShellListener listener) {}

  @override
  Future<void> destroy() async {}

  @override
  void popUpContextMenu() {}

  @override
  void removeListener(TrayShellListener listener) {}

  @override
  Future<void> setContextMenu(TrayMenuModel menu) async {}

  @override
  Future<void> setIcon(String path) async {}
}
