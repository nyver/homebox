import 'package:flutter/services.dart';

/// Size and last-modified time of one document in the Android sync folder,
/// as reported by its Storage Access Framework provider. [modified] is null
/// when the provider does not track modification times.
final class AndroidDocumentStat {
  const AndroidDocumentStat({required this.size, this.modified});

  final int size;
  final DateTime? modified;

  static AndroidDocumentStat? fromChannel(Object? value) {
    if (value is! Map) return null;
    final size = value['size'];
    if (size is! int || size < 0) return null;
    final modified = value['modified'];
    return AndroidDocumentStat(
      size: size,
      modified: modified is int && modified > 0
          ? DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true)
          : null,
    );
  }
}

/// Android's Storage Access Framework boundary for the user-selected sync
/// folder. The persisted tree URI grants access only to that folder, without
/// requesting the broad "All files access" permission.
abstract interface class AndroidSyncFolder {
  Future<String?> selectFolder();

  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  });

  /// Copies [sourcePath] into the tree and returns the written document's
  /// stat, so a later scan can tell an untouched copy from a local edit.
  Future<AndroidDocumentStat?> writeFile({
    required String treeUri,
    required String relativePath,
    required String sourcePath,
  });

  Future<bool> fileExists({
    required String treeUri,
    required String relativePath,
  });

  /// The stat of one file, or null when it is no longer present.
  Future<AndroidDocumentStat?> statFile({
    required String treeUri,
    required String relativePath,
  });

  /// Every regular file under the tree, keyed by its '/'-separated relative
  /// path. One recursive provider query instead of one lookup per file.
  Future<Map<String, AndroidDocumentStat>> listFiles({required String treeUri});

  /// Lowercase hex SHA-256 of a file's content, computed natively so an
  /// unchanged file never has to be copied out of the tree. Null when the
  /// file is no longer present.
  Future<String?> hashFile({
    required String treeUri,
    required String relativePath,
  });

  /// Copies a file out of the tree into [destinationPath], which must be in
  /// the application's private cache. Returns false when the file is gone.
  Future<bool> readFile({
    required String treeUri,
    required String relativePath,
    required String destinationPath,
  });

  Future<void> deleteFile({
    required String treeUri,
    required String relativePath,
  });

  /// Opens an already materialized file with an Android application, which
  /// may save edits back; the sync pass then uploads them as a new version.
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
  Future<String?> selectFolder() =>
      _channel.invokeMethod<String>('selectFolder');

  @override
  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  }) => _channel.invokeMethod<void>('createDirectory', {
    'treeUri': treeUri,
    'relativePath': relativePath,
  });

  @override
  Future<AndroidDocumentStat?> writeFile({
    required String treeUri,
    required String relativePath,
    required String sourcePath,
  }) async => AndroidDocumentStat.fromChannel(
    await _channel.invokeMethod<Object?>('writeFile', {
      'treeUri': treeUri,
      'relativePath': relativePath,
      'sourcePath': sourcePath,
    }),
  );

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
  Future<AndroidDocumentStat?> statFile({
    required String treeUri,
    required String relativePath,
  }) async => AndroidDocumentStat.fromChannel(
    await _channel.invokeMethod<Object?>('statFile', {
      'treeUri': treeUri,
      'relativePath': relativePath,
    }),
  );

  @override
  Future<Map<String, AndroidDocumentStat>> listFiles({
    required String treeUri,
  }) async {
    final raw = await _channel.invokeListMethod<Object?>('listFiles', {
      'treeUri': treeUri,
    });
    final files = <String, AndroidDocumentStat>{};
    for (final entry in raw ?? const <Object?>[]) {
      if (entry is! Map) continue;
      final path = entry['path'];
      final stat = AndroidDocumentStat.fromChannel(entry);
      if (path is String && path.isNotEmpty && stat != null) {
        files[path] = stat;
      }
    }
    return files;
  }

  @override
  Future<String?> hashFile({
    required String treeUri,
    required String relativePath,
  }) => _channel.invokeMethod<String>('hashFile', {
    'treeUri': treeUri,
    'relativePath': relativePath,
  });

  @override
  Future<bool> readFile({
    required String treeUri,
    required String relativePath,
    required String destinationPath,
  }) async =>
      await _channel.invokeMethod<bool>('readFile', {
        'treeUri': treeUri,
        'relativePath': relativePath,
        'destinationPath': destinationPath,
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
