import 'dart:io';

import 'package:archive/archive_io.dart';

import '../../core/e2ee/opaque_id.dart';

/// One file or folder of a multi-item download. [relativePath] uses '/'
/// separators and consists of decrypted names that already passed
/// [PortableName] validation, so it cannot escape the destination.
final class DownloadItem {
  const DownloadItem.file({
    required this.relativePath,
    required this.nodeId,
    this.versionId,
    this.plaintextSha256,
    this.size,
  }) : isDirectory = false;

  const DownloadItem.directory(this.relativePath)
    : isDirectory = true,
      nodeId = null,
      versionId = null,
      plaintextSha256 = null,
      size = null;

  final String relativePath;
  final bool isDirectory;
  final String? nodeId;
  final String? versionId;
  final String? plaintextSha256;
  final int? size;
}

/// Decrypts one file item to [destinationPath], reporting 0..1 progress.
typedef DownloadOneFile = Future<void> Function(
  DownloadItem item,
  String destinationPath,
  void Function(double progress) onProgress,
);

/// Writes [items] below [directory], creating folders as needed. A
/// top-level name that already exists there gets a " (n)" suffix instead of
/// overwriting anything. Returns how many files were written.
Future<int> downloadItemsToDirectory({
  required List<DownloadItem> items,
  required String directory,
  required DownloadOneFile download,
  void Function(double progress)? onProgress,
}) async {
  final renamedTops = <String, String>{};
  String target(DownloadItem item) {
    final segments = item.relativePath.split('/');
    final top = renamedTops.putIfAbsent(
      segments.first,
      () => _unusedName(directory, segments.first),
    );
    return [directory, top, ...segments.skip(1)].join(Platform.pathSeparator);
  }

  final progress = _Progress(items, onProgress);
  var written = 0;
  for (final item in items) {
    final path = target(item);
    if (item.isDirectory) {
      await Directory(path).create(recursive: true);
      continue;
    }
    await File(path).parent.create(recursive: true);
    await download(item, path, (p) => progress.update(item, p));
    progress.complete(item);
    written++;
  }
  return written;
}

/// Packs [items] into a ZIP file at [zipPath]. Files are decrypted one at a
/// time into a private temporary folder and streamed into the archive, so
/// memory stays bounded; the archive only appears at [zipPath] once it is
/// complete, and every temporary plaintext copy is removed afterwards.
Future<int> downloadItemsAsZip({
  required List<DownloadItem> items,
  required String zipPath,
  required DownloadOneFile download,
  void Function(double progress)? onProgress,
}) async {
  final staging = await Directory.systemTemp.createTemp('homebox-zip-');
  final partial = '$zipPath.homebox-tmp-${generateUuidV4()}';
  final encoder = ZipFileEncoder();
  var open = false;
  try {
    encoder.create(partial);
    open = true;
    final progress = _Progress(items, onProgress);
    var written = 0;
    for (final item in items) {
      if (item.isDirectory) continue;
      final plain = File(
        '${staging.path}${Platform.pathSeparator}${generateUuidV4()}',
      );
      try {
        await download(item, plain.path, (p) => progress.update(item, p));
        await encoder.addFile(plain, item.relativePath);
      } finally {
        if (await plain.exists()) await plain.delete();
      }
      progress.complete(item);
      written++;
    }
    await encoder.close();
    open = false;
    final destination = File(zipPath);
    if (await destination.exists()) await destination.delete();
    await File(partial).rename(zipPath);
    return written;
  } finally {
    if (open) {
      try {
        await encoder.close();
      } catch (_) {
        // The partial archive is deleted below either way.
      }
    }
    final leftover = File(partial);
    if (await leftover.exists()) await leftover.delete();
    await staging.delete(recursive: true);
  }
}

/// "name", or "name (2).ext" etc. when "name" exists in [directory].
String _unusedName(String directory, String name) {
  bool taken(String candidate) =>
      FileSystemEntity.typeSync(
        '$directory${Platform.pathSeparator}$candidate',
      ) !=
      FileSystemEntityType.notFound;
  if (!taken(name)) return name;
  final dot = name.lastIndexOf('.');
  final hasExtension = dot > 0;
  final base = hasExtension ? name.substring(0, dot) : name;
  final extension = hasExtension ? name.substring(dot) : '';
  for (var n = 2; ; n++) {
    final candidate = '$base ($n)$extension';
    if (!taken(candidate)) return candidate;
  }
}

/// Overall progress weighted by file size (one unit for unknown sizes).
final class _Progress {
  _Progress(List<DownloadItem> items, this._report)
    : _total = items
          .where((item) => !item.isDirectory)
          .fold<int>(0, (sum, item) => sum + _weight(item));

  final void Function(double progress)? _report;
  final int _total;
  int _done = 0;

  static int _weight(DownloadItem item) =>
      (item.size ?? 0) > 0 ? item.size! : 1;

  void update(DownloadItem item, double fraction) {
    if (_total == 0) return;
    _report?.call(((_done + _weight(item) * fraction) / _total).clamp(0, 1));
  }

  void complete(DownloadItem item) {
    _done += _weight(item);
    if (_total > 0) _report?.call((_done / _total).clamp(0, 1));
  }
}
