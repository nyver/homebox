import 'dart:io';

import '../../core/e2ee/opaque_id.dart';
import '../../core/storage/materialized_files_store.dart';
import '../../core/storage/sync_conflicts_store.dart';
import '../files/file_transfer.dart';
import '../sync/conflict_naming.dart';
import '../sync/sync_conflict_log.dart';

/// True when the local [file] still holds exactly what [record] says this
/// device last synchronized, i.e. replacing or removing it loses nothing.
/// An unchanged size and timestamp is trusted without reading the file;
/// otherwise the content hash decides. A record without a known hash cannot
/// prove anything, so such a copy counts as edited. [knownSha256] skips
/// re-hashing when the caller has just hashed the same file.
Future<bool> localCopyMatchesRecord(
  MaterializedFile record,
  File file, {
  String? knownSha256,
}) async {
  final stat = await file.stat();
  if (stat.type == FileSystemEntityType.notFound) return true;
  if (record.matchesLocalStat(stat)) return true;
  final recorded = record.contentSha256;
  if (recorded == null) return false;
  final actual = knownSha256 ?? await plaintextFileSha256(file);
  return actual.toLowerCase() == recorded.toLowerCase();
}

/// Renames the local file at [relativePath] (under [rootPath]) to a fresh
/// conflict-copy name in the same folder (spec §21), records the conflict in
/// [conflicts], and returns the copy's relative path. The bytes never move
/// between volumes, so this is a cheap, atomic rename. The copy is a normal
/// untracked local file afterwards: the next uploader scan publishes it as a
/// new node carrying encrypted conflict details.
Future<String> preserveAsConflictCopy({
  required String rootPath,
  required String relativePath,
  required SyncConflictLog conflicts,
  required SyncConflictKind kind,
  required String deviceName,
  String? nodeId,
}) async {
  final slash = relativePath.lastIndexOf('/');
  final directory = slash == -1 ? '' : relativePath.substring(0, slash);
  final name = slash == -1 ? relativePath : relativePath.substring(slash + 1);
  String inDirectory(String copyName) =>
      directory.isEmpty ? copyName : '$directory/$copyName';

  final detectedAt = DateTime.now().toUtc();
  var copyName = conflictCopyName(
    name,
    deviceName: deviceName,
    detectedAt: detectedAt,
  );
  for (var attempt = 0; ; attempt++) {
    final type = await FileSystemEntity.type(
      '$rootPath/${inDirectory(copyName)}',
    );
    if (type == FileSystemEntityType.notFound) break;
    if (attempt == 5) {
      throw StateError('No free conflict-copy name for $name.');
    }
    // Spec §21: "Если имя уже существует, добавить короткий ID".
    copyName = conflictCopyName(
      name,
      deviceName: deviceName,
      detectedAt: detectedAt,
      uniqueSuffix: generateUuidV4().substring(0, 8),
    );
  }
  final copyPath = inDirectory(copyName);
  await File('$rootPath/$relativePath').rename('$rootPath/$copyPath');
  conflicts.record(
    kind: kind,
    nodeId: nodeId,
    fileName: name,
    conflictCopyPath: copyPath,
    detectedAt: detectedAt,
  );
  return copyPath;
}

/// The reason embedded in an uploaded conflict copy's encrypted details.
String conflictCopyReason(SyncConflictKind kind) => switch (kind) {
  SyncConflictKind.bothModified =>
    'it was changed on this device and on another device at the same time.',
  SyncConflictKind.bothCreated =>
    'a different file with the same name already existed in the vault.',
  SyncConflictKind.modifiedLocallyDeletedRemotely =>
    'it was edited on this device after another device deleted it.',
  SyncConflictKind.renameRejected ||
  SyncConflictKind.moveRejected ||
  SyncConflictKind.deleteRejected => 'it conflicted with another device.',
};
