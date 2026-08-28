import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SyncFolderStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class PlatformSyncFolderStorage implements SyncFolderStorage {
  const PlatformSyncFolderStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Persists the user's chosen local sync-folder path (spec §8) across
/// restarts. A single global setting, matching this client's single
/// pinned-server/single-vault-per-account shape today.
final class SyncFolderStore {
  SyncFolderStore([SyncFolderStorage? storage]) : _storage = storage ?? const PlatformSyncFolderStorage();

  static const String _key = 'homebox.syncfolder.path.v1';

  final SyncFolderStorage _storage;

  Future<String?> load() => _storage.read(_key);

  Future<void> save(String path) => _storage.write(_key, path);

  Future<void> clear() => _storage.delete(_key);
}
