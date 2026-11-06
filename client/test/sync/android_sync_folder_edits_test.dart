import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/android_sync_folder.dart';
import 'package:homebox_client/core/storage/materialized_files_store.dart';
import 'package:homebox_client/core/storage/sync_conflicts_store.dart';
import 'package:homebox_client/features/files/file_transfer.dart';
import 'package:homebox_client/features/syncfolder/local_folder_uploader.dart';
import 'package:homebox_client/features/syncfolder/sync_folder_materializer.dart';

import 'conflict_test_harness.dart';

/// A Storage Access Framework tree played by a plain directory: the tree URI
/// is the directory's path. Counts reads so tests can prove that an untouched
/// file is never hashed or copied out of the tree.
final class DirectoryAndroidSyncFolder implements AndroidSyncFolder {
  int hashCalls = 0;
  int readCalls = 0;

  File _file(String treeUri, String relativePath) =>
      File('$treeUri/$relativePath');

  Future<AndroidDocumentStat?> _stat(File file) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return AndroidDocumentStat(size: stat.size, modified: stat.modified);
  }

  @override
  Future<String?> selectFolder() async => null;

  @override
  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  }) => Directory('$treeUri/$relativePath').create(recursive: true);

  @override
  Future<AndroidDocumentStat?> writeFile({
    required String treeUri,
    required String relativePath,
    required String sourcePath,
  }) async {
    final target = _file(treeUri, relativePath);
    await target.parent.create(recursive: true);
    await File(sourcePath).copy(target.path);
    return _stat(target);
  }

  @override
  Future<bool> fileExists({
    required String treeUri,
    required String relativePath,
  }) => _file(treeUri, relativePath).exists();

  @override
  Future<AndroidDocumentStat?> statFile({
    required String treeUri,
    required String relativePath,
  }) => _stat(_file(treeUri, relativePath));

  @override
  Future<Map<String, AndroidDocumentStat>> listFiles({
    required String treeUri,
  }) async {
    final files = <String, AndroidDocumentStat>{};
    await for (final entity in Directory(treeUri).list(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(treeUri.length + 1)
          .replaceAll('\\', '/');
      final stat = await _stat(entity);
      if (stat != null) files[relative] = stat;
    }
    return files;
  }

  @override
  Future<String?> hashFile({
    required String treeUri,
    required String relativePath,
  }) async {
    hashCalls++;
    final file = _file(treeUri, relativePath);
    return await file.exists() ? plaintextFileSha256(file) : null;
  }

  @override
  Future<bool> readFile({
    required String treeUri,
    required String relativePath,
    required String destinationPath,
  }) async {
    readCalls++;
    final file = _file(treeUri, relativePath);
    if (!await file.exists()) return false;
    await file.copy(destinationPath);
    return true;
  }

  @override
  Future<void> deleteFile({
    required String treeUri,
    required String relativePath,
  }) async {
    final file = _file(treeUri, relativePath);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> openFile({
    required String treeUri,
    required String relativePath,
    String? mimeType,
  }) async => true;
}

final class _AndroidDevice {
  _AndroidDevice(this.h, this.folder, this.materializer, this.uploader);

  final ConflictHarness h;
  final DirectoryAndroidSyncFolder folder;
  final SyncFolderMaterializer materializer;
  final LocalFolderUploader uploader;

  String get tree => h.root.path;
  File file(String relativePath) => File('$tree/$relativePath');

  /// One sync-folder pass in the order main.dart runs it on Android.
  Future<void> pass() async {
    await uploader.scanAndroidEdits(tree);
    expect(
      uploader.status,
      LocalUploadStatus.idle,
      reason: uploader.errorMessage,
    );
    await materializer.materialize(tree);
    expect(
      materializer.status,
      SyncFolderStatus.idle,
      reason: materializer.errorMessage,
    );
  }

  static Future<_AndroidDevice> create() async {
    final h = await ConflictHarness.create();
    final folder = DirectoryAndroidSyncFolder();
    final materializer = SyncFolderMaterializer(
      serverConnection: h.serverConnection,
      vaultKeyStore: h.vaultKeyStore,
      syncEngine: h.engine,
      androidSyncFolder: folder,
      deviceName: conflictTestDeviceName,
    );
    addTearDown(materializer.dispose);
    final uploader = LocalFolderUploader(
      serverConnection: h.serverConnection,
      vaultKeyStore: h.vaultKeyStore,
      syncEngine: h.engine,
      androidSyncFolder: folder,
      deviceName: conflictTestDeviceName,
    );
    addTearDown(uploader.dispose);
    return _AndroidDevice(h, folder, materializer, uploader);
  }
}

/// Moves a file's modification time away from what the materializer
/// recorded, as an editing app saving the file would.
Future<void> _touch(File file) => file.setLastModified(
  file.lastModifiedSync().add(const Duration(seconds: 5)),
);

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'an edit saved by another app is uploaded as the next version',
    () async {
      final d = await _AndroidDevice.create();
      final entry = await d.h.uploadRootFile('note.txt', 'version one');
      await d.pass();
      final record = d.h.engine.materializedFiles.getById(entry.node.id)!;
      expect(record.localSize, 'version one'.length);
      expect(record.localModifiedAt, isNotNull);

      await d.file('note.txt').writeAsString('edited in a text editor');
      await _touch(d.file('note.txt'));
      await d.pass();

      expect(await d.h.serverContent(entry.node.id), 'edited in a text editor');
      final metadata = await d.h.serverMetadata(entry.node.id);
      expect(metadata.fileName, 'note.txt');
      expect(metadata.plaintextSha256, sha256Hex('edited in a text editor'));
      final updated = d.h.engine.nodeCache.getById(entry.node.id)!;
      expect(updated.currentVersionId, isNot(entry.node.currentVersionId));
      final updatedRecord = d.h.engine.materializedFiles.getById(
        entry.node.id,
      )!;
      expect(updatedRecord.contentVersionId, updated.currentVersionId);
      expect(updatedRecord.contentSha256, sha256Hex('edited in a text editor'));
      expect(
        await d.file('note.txt').readAsString(),
        'edited in a text editor',
      );
      expect(d.h.engine.conflicts.open, isEmpty);

      // Nothing changed since: the next pass neither hashes nor uploads.
      final hashes = d.folder.hashCalls;
      await d.pass();
      expect(d.folder.hashCalls, hashes);
      expect(
        d.h.engine.nodeCache.getById(entry.node.id)!.currentVersionId,
        updated.currentVersionId,
      );
    },
  );

  test(
    'a file whose timestamp changed but content did not is not uploaded',
    () async {
      final d = await _AndroidDevice.create();
      final entry = await d.h.uploadRootFile('photo.jpg', 'pixels');
      await d.pass();

      await _touch(d.file('photo.jpg'));
      await d.pass();

      expect(d.folder.hashCalls, 1);
      expect(d.folder.readCalls, 0);
      expect(
        d.h.engine.nodeCache.getById(entry.node.id)!.currentVersionId,
        entry.node.currentVersionId,
      );
      final record = d.h.engine.materializedFiles.getById(entry.node.id)!;
      expect(
        record.localModifiedAt!.millisecondsSinceEpoch,
        d.file('photo.jpg').lastModifiedSync().millisecondsSinceEpoch,
      );
      await d.pass();
      expect(d.folder.hashCalls, 1);
    },
  );

  test('a refused upload is not re-read every cycle, but a new edit retries at once', () async {
    final d = await _AndroidDevice.create();
    final entry = await d.h.uploadRootFile('note.txt', 'version one');
    await d.pass();

    await d.file('note.txt').writeAsString('first edit');
    await _touch(d.file('note.txt'));
    d.h.fakeServer
      ..failMutationsWithStatus = 503
      ..failMutationsWithCode = 'INTERNAL_ERROR';
    await d.uploader.scanAndroidEdits(d.tree);
    expect(d.folder.readCalls, 1);
    await d.uploader.scanAndroidEdits(d.tree);
    expect(d.folder.readCalls, 1, reason: 'the same refused edit waits');
    // The edit survives a pull in the meantime.
    await d.materializer.materialize(d.tree);
    expect(await d.file('note.txt').readAsString(), 'first edit');

    d.h.fakeServer
      ..failMutationsWithStatus = null
      ..failMutationsWithCode = null;
    await d.file('note.txt').writeAsString('second, longer edit');
    await _touch(d.file('note.txt'));
    await d.pass();
    expect(d.folder.readCalls, 2);
    expect(await d.h.serverContent(entry.node.id), 'second, longer edit');
  });

  test('a record written before stats were tracked gets a baseline instead of an upload', () async {
    final d = await _AndroidDevice.create();
    final entry = await d.h.uploadRootFile('old.txt', 'mirrored long ago');
    await d.pass();
    final record = d.h.engine.materializedFiles.getById(entry.node.id)!;
    d.h.engine.materializedFiles.upsert(
      MaterializedFile(
        nodeId: record.nodeId,
        relativePath: record.relativePath,
        contentVersionId: record.contentVersionId,
        contentSha256: record.contentSha256,
      ),
    );

    await d.pass();

    expect(
      d.h.engine.nodeCache.getById(entry.node.id)!.currentVersionId,
      entry.node.currentVersionId,
    );
    expect(
      d.h.engine.materializedFiles.getById(entry.node.id)!.localSize,
      'mirrored long ago'.length,
    );
  });

  test(
    'a pull never overwrites an edit that has not been uploaded yet',
    () async {
      final d = await _AndroidDevice.create();
      final entry = await d.h.uploadRootFile('note.txt', 'version one');
      await d.pass();

      await d.file('note.txt').writeAsString('edited on the phone');
      await _touch(d.file('note.txt'));
      await d.h.remoteReplaceContent(entry.node.id, 'edited elsewhere');
      await d.h.engine.runOnce();

      // Materialize alone, as if the edit landed after the uploader's pass.
      await d.materializer.materialize(d.tree);
      expect(await d.file('note.txt').readAsString(), 'edited on the phone');
    },
  );

  test(
    'an edit racing a remote update is kept as an uploaded conflict copy',
    () async {
      final d = await _AndroidDevice.create();
      final entry = await d.h.uploadRootFile('note.txt', 'version one');
      await d.pass();

      await d.file('note.txt').writeAsString('edited on the phone');
      await _touch(d.file('note.txt'));
      await d.h.remoteReplaceContent(entry.node.id, 'edited elsewhere');
      await d.h.engine.runOnce();
      await d.pass();

      expect(await d.h.serverContent(entry.node.id), 'edited elsewhere');
      expect(await d.file('note.txt').readAsString(), 'edited elsewhere');
      await d.h.files.refresh();
      final copy = d.h.files.entries.singleWhere((e) => e.isConflictCopy);
      expect(conflictCopyPattern('note', '.txt').hasMatch(copy.name), isTrue);
      expect(copy.metadata.conflictDetails, contains('"note.txt"'));
      expect(await d.h.serverContent(copy.node.id), 'edited on the phone');
      expect(await d.file(copy.name).readAsString(), 'edited on the phone');
      final conflict = d.h.engine.conflicts.open.single;
      expect(conflict.kind, SyncConflictKind.bothModified);
      expect(conflict.copyNodeId, copy.node.id);
      expect(conflict.conflictCopyPath, copy.name);

      // Settled: another pass changes nothing.
      await d.pass();
      await d.h.files.refresh();
      expect(d.h.files.entries, hasLength(2));
      expect(d.h.engine.conflicts.open, hasLength(1));
    },
  );

  test(
    'an edit to a file deleted elsewhere survives as a conflict copy',
    () async {
      final d = await _AndroidDevice.create();
      final entry = await d.h.uploadRootFile('report.docx', 'draft');
      await d.pass();

      await d.file('report.docx').writeAsString('final wording');
      await _touch(d.file('report.docx'));
      expect(await d.h.files.deleteNode(entry), isTrue);
      await d.h.engine.runOnce();

      // The prune keeps the unsynced edit, and its record, even without the
      // uploader's pass.
      await d.materializer.materialize(d.tree);
      expect(await d.file('report.docx').readAsString(), 'final wording');
      expect(d.h.engine.materializedFiles.getById(entry.node.id), isNotNull);

      await d.pass();

      await d.h.files.refresh();
      final restored = d.h.files.entries.single;
      expect(restored.isConflictCopy, isTrue);
      expect(
        conflictCopyPattern('report', '.docx').hasMatch(restored.name),
        isTrue,
      );
      expect(await d.h.serverContent(restored.node.id), 'final wording');
      expect(await d.file('report.docx').exists(), isFalse);
      expect(await d.file(restored.name).readAsString(), 'final wording');
      expect(
        d.h.engine.conflicts.open.single.kind,
        SyncConflictKind.modifiedLocallyDeletedRemotely,
      );
    },
  );
}
