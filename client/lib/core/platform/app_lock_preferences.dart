import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// When an unlocked app locks again after being in the background. There is
/// deliberately no "immediately": system pickers and the camera briefly
/// background HomeBox as part of normal use (see [BiometricAuthenticator]).
enum AppAutoLock {
  onLaunchOnly(null),
  after1Minute(Duration(minutes: 1)),
  after5Minutes(Duration(minutes: 5)),
  after15Minutes(Duration(minutes: 15));

  const AppAutoLock(this.after);

  /// Time in the background after which the app locks; null never relocks.
  final Duration? after;
}

abstract interface class AppLockStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

final class PlatformAppLockStorage implements AppLockStorage {
  const PlatformAppLockStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// The biometric app-lock choices for this device: whether HomeBox asks for
/// biometrics at all, and when it locks again after being backgrounded.
final class AppLockPreferences extends ChangeNotifier {
  AppLockPreferences([AppLockStorage? storage])
    : _storage = storage ?? const PlatformAppLockStorage();

  static const _enabledKey = 'homebox.app_lock.enabled.v1';
  static const _autoLockKey = 'homebox.app_lock.auto.v1';

  final AppLockStorage _storage;
  bool _enabled = true;
  AppAutoLock _autoLock = AppAutoLock.after5Minutes;

  bool get enabled => _enabled;
  AppAutoLock get autoLock => _autoLock;

  /// Loads the saved choices. A storage failure keeps the safe defaults
  /// (locked, relocking after five minutes) rather than blocking startup.
  Future<void> initialize() async {
    try {
      final enabled = await _storage.read(_enabledKey);
      final autoLock = await _storage.read(_autoLockKey);
      _enabled = enabled != 'false';
      _autoLock =
          AppAutoLock.values.where((v) => v.name == autoLock).firstOrNull ??
          _autoLock;
    } catch (_) {
      return;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    if (enabled == _enabled) return;
    _enabled = enabled;
    notifyListeners();
    await _write(_enabledKey, '$enabled');
  }

  Future<void> setAutoLock(AppAutoLock autoLock) async {
    if (autoLock == _autoLock) return;
    _autoLock = autoLock;
    notifyListeners();
    await _write(_autoLockKey, autoLock.name);
  }

  /// Whether returning after [away] in the background should lock the app.
  bool shouldLockAfter(Duration away) {
    final limit = _autoLock.after;
    return _enabled && limit != null && away >= limit;
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key, value);
    } catch (_) {
      // The choice still applies for this app session.
    }
  }
}
