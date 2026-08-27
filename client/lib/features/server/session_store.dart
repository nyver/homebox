import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class PlatformSessionStorage implements SessionStorage {
  const PlatformSessionStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Persists the durable half of a login session: the refresh token (spec
/// §16.1) and a stable, client-generated device ID reused across restarts
/// so the server recognizes the same device on every login instead of
/// registering a new one each time. The short-lived access token is
/// deliberately not persisted here — it lives only in memory and is
/// re-derived from the refresh token on startup.
final class SessionStore {
  SessionStore([SessionStorage? storage]) : _storage = storage ?? const PlatformSessionStorage();

  static const String _refreshTokenKey = 'homebox.transport.session.refresh_token.v1';
  static const String _deviceIdKey = 'homebox.transport.session.device_id.v1';

  final SessionStorage _storage;

  Future<String?> loadRefreshToken() => _storage.read(_refreshTokenKey);

  Future<void> saveRefreshToken(String token) => _storage.write(_refreshTokenKey, token);

  Future<void> clearRefreshToken() => _storage.delete(_refreshTokenKey);

  Future<String> loadOrCreateDeviceId() async {
    final existing = await _storage.read(_deviceIdKey);
    if (existing != null) return existing;
    final generated = _generateUuidV4(math.Random.secure());
    await _storage.write(_deviceIdKey, generated);
    return generated;
  }
}

String _generateUuidV4(math.Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  String hexRange(int start, int end) =>
      bytes.sublist(start, end).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hexRange(0, 4)}-${hexRange(4, 6)}-${hexRange(6, 8)}-${hexRange(8, 10)}-${hexRange(10, 16)}';
}
