import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class PinnedServerStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class PlatformPinnedServerStorage implements PinnedServerStorage {
  const PlatformPinnedServerStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A server the user has explicitly trusted, identified by its pinned
/// identity fingerprint rather than a certificate authority (ADR-009).
/// Corresponds to spec §13's local `pinned_servers` table.
final class PinnedServer {
  const PinnedServer({required this.baseUrl, required this.fingerprint});

  final String baseUrl;
  final String fingerprint;

  Map<String, String> _toJson() => {'baseUrl': baseUrl, 'fingerprint': fingerprint};

  static PinnedServer? _tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final baseUrl = json['baseUrl'];
    final fingerprint = json['fingerprint'];
    if (baseUrl is! String || fingerprint is! String) return null;
    return PinnedServer(baseUrl: baseUrl, fingerprint: fingerprint);
  }
}

/// Persists the single currently-trusted server. Multiple pinned servers per
/// device are a possible later UX improvement; today's clients only ever
/// connect to one HomeBox server at a time.
final class PinnedServerStore {
  PinnedServerStore([PinnedServerStorage? storage]) : _storage = storage ?? const PlatformPinnedServerStorage();

  static const String _key = 'homebox.transport.pinned_server.v1';

  final PinnedServerStorage _storage;

  Future<PinnedServer?> load() async {
    final raw = await _storage.read(_key);
    if (raw == null) return null;
    try {
      return PinnedServer._tryFromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> save(PinnedServer server) => _storage.write(_key, jsonEncode(server._toJson()));

  Future<void> clear() => _storage.delete(_key);
}
