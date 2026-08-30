import 'package:flutter/services.dart';

/// Android's Storage Access Framework boundary for the user-selected sync
/// folder. The persisted tree URI grants access only to that folder, without
/// requesting the broad "All files access" permission.
abstract interface class AndroidSyncFolder {
  Future<String?> selectFolder();

  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  });

  Future<void> writeFile({
    required String treeUri,
    required String relativePath,
    required String sourcePath,
  });

  Future<bool> fileExists({
    required String treeUri,
    required String relativePath,
  });

  Future<void> deleteFile({
    required String treeUri,
    required String relativePath,
  });

  /// Opens an already materialized file with an Android application.
  /// Returns false when the file is no longer present in the selected tree.
  Future<bool> openFile({
    required String treeUri,
    required String relativePath,
    String? mimeType,
  });
}

final class MethodChannelAndroidSyncFolder implements AndroidSyncFolder {
  MethodChannelAndroidSyncFolder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('homebox/sync_folder');

  final MethodChannel _channel;

  @override
  Future<String?> selectFolder() => _channel.invokeMethod<String>('selectFolder');

  @override
  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  }) => _channel.invokeMethod<void>('createDirectory', {
    'treeUri': treeUri,
    'relativePath': relativePath,
  });

  @override
  Future<void> writeFile({
    required String treeUri,
    required String relativePath,
    required String sourcePath,
  }) => _channel.invokeMethod<void>('writeFile', {
    'treeUri': treeUri,
    'relativePath': relativePath,
    'sourcePath': sourcePath,
  });

  @override
  Future<bool> fileExists({
    required String treeUri,
    required String relativePath,
  }) async =>
      await _channel.invokeMethod<bool>('fileExists', {
        'treeUri': treeUri,
        'relativePath': relativePath,
      }) ??
      false;

  @override
  Future<void> deleteFile({
    required String treeUri,
    required String relativePath,
  }) => _channel.invokeMethod<void>('deleteFile', {
    'treeUri': treeUri,
    'relativePath': relativePath,
  });

  @override
  Future<bool> openFile({
    required String treeUri,
    required String relativePath,
    String? mimeType,
  }) async =>
      await _channel.invokeMethod<bool>('openFile', {
        'treeUri': treeUri,
        'relativePath': relativePath,
        'mimeType': mimeType ?? 'application/octet-stream',
      }) ??
      false;
}
