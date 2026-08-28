import 'package:homebox_client/features/syncfolder/sync_folder_store.dart';

final class MemorySyncFolderStorage implements SyncFolderStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
