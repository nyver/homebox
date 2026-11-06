import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/app_lock_preferences.dart';

final class _MemoryLockStorage implements AppLockStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test('defaults lock at launch and again after five minutes away', () async {
    final prefs = AppLockPreferences(_MemoryLockStorage());
    addTearDown(prefs.dispose);
    await prefs.initialize();

    expect(prefs.enabled, isTrue);
    expect(prefs.autoLock, AppAutoLock.after5Minutes);
    expect(prefs.shouldLockAfter(const Duration(seconds: 30)), isFalse);
    expect(prefs.shouldLockAfter(const Duration(minutes: 5)), isTrue);
  });

  test('choices persist and control relocking', () async {
    final storage = _MemoryLockStorage();
    final prefs = AppLockPreferences(storage);
    addTearDown(prefs.dispose);
    await prefs.setAutoLock(AppAutoLock.onLaunchOnly);
    expect(prefs.shouldLockAfter(const Duration(days: 1)), isFalse);

    await prefs.setAutoLock(AppAutoLock.after1Minute);
    await prefs.setEnabled(false);
    expect(prefs.shouldLockAfter(const Duration(hours: 1)), isFalse);

    final reloaded = AppLockPreferences(storage);
    addTearDown(reloaded.dispose);
    await reloaded.initialize();
    expect(reloaded.enabled, isFalse);
    expect(reloaded.autoLock, AppAutoLock.after1Minute);
  });
}
