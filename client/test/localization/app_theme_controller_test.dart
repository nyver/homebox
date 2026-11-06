import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/localization/app_theme_controller.dart';

final class _MemoryThemeStorage implements AppThemeStorage {
  _MemoryThemeStorage([this.value]);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String themeMode) async {
    value = themeMode;
  }
}

final class _FailingThemeStorage implements AppThemeStorage {
  @override
  Future<String?> read() => Future.error(StateError('unavailable'));

  @override
  Future<void> write(String themeMode) => Future.error(StateError('nope'));
}

void main() {
  test('restores and persists the selected appearance', () async {
    final storage = _MemoryThemeStorage('dark');
    final controller = AppThemeController(storage);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.mode, ThemeMode.dark);

    await controller.setMode(ThemeMode.light);
    expect(controller.mode, ThemeMode.light);
    expect(storage.value, 'light');
  });

  test(
    'unknown values and storage failures fall back to the system theme',
    () async {
      final unknown = AppThemeController(_MemoryThemeStorage('sepia'));
      addTearDown(unknown.dispose);
      await unknown.initialize();
      expect(unknown.mode, ThemeMode.system);

      final failing = AppThemeController(_FailingThemeStorage());
      addTearDown(failing.dispose);
      await failing.initialize();
      expect(failing.mode, ThemeMode.system);
      await failing.setMode(ThemeMode.dark);
      expect(failing.mode, ThemeMode.dark);
    },
  );
}
