import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class AppThemeStorage {
  Future<String?> read();

  Future<void> write(String themeMode);
}

final class PlatformAppThemeStorage implements AppThemeStorage {
  const PlatformAppThemeStorage([this._storage = const FlutterSecureStorage()]);

  static const _key = 'homebox.app_theme.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String themeMode) =>
      _storage.write(key: _key, value: themeMode);
}

/// Holds the user's light/dark/system appearance choice for this device.
final class AppThemeController extends ChangeNotifier {
  AppThemeController([AppThemeStorage? storage])
    : _storage = storage ?? const PlatformAppThemeStorage();

  final AppThemeStorage _storage;
  ThemeMode _mode = ThemeMode.system;

  ThemeMode get mode => _mode;

  Future<void> initialize() async {
    String? stored;
    try {
      stored = await _storage.read();
    } catch (_) {
      return; // An appearance preference must never prevent app startup.
    }
    final mode = ThemeMode.values
        .where((candidate) => candidate.name == stored)
        .firstOrNull;
    if (mode == null || mode == _mode) return;
    _mode = mode;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await _storage.write(mode.name);
    } catch (_) {
      // The selected appearance remains active for this app session.
    }
  }
}
