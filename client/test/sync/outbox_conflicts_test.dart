import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/sync_conflicts_store.dart';

import 'conflict_test_harness.dart';

/// Spec §21 for the durable outbox: an offline rename/move/delete that lost
/// a revision race is replayed onto the server's newer state when the two
/// changes are compatible, and otherwise keeps the server state and reports
/// the conflict instead of silently dropping or overwriting anything.
void main() {
  test('a folder created and then renamed offline reaches the server with the new name', () async {
    final h = await ConflictHarness.create();
    h.engine.pause();
    expect(await h.files.createFolder('Draft'), isTrue);
    expect(await h.files.renameNode(h.files.entries.single, 'Final'), isTrue);
    expect(
      await h.files.renameNode(h.files.entries.single, 'Final v2'),
      isTrue,
    );

    h.engine.resume();
    await h.engine.runOnce();

    final folder = h.files.entries.single;
    expect((await h.serverMetadata(folder.node.id)).fileName, 'Final v2');
    expect(h.engine.pendingOperations.hasUnfinishedOperations, isFalse);
    expect(h.engine.conflicts.open, isEmpty);
  });

  test('a rename queued before a remote content update is replayed onto the new version', () async {
    final h = await ConflictHarness.create();
    final entry = await h.uploadRootFile('a.txt', 'first');
    h.engine.pause();
    expect(await h.files.renameNode(entry, 'b.txt'), isTrue);
    await h.remoteReplaceContent(entry.node.id, 'second, from the phone');

    h.engine.resume();
    await h.engine.runOnce();

    final metadata = await h.serverMetadata(entry.node.id);
    expect(metadata.fileName, 'b.txt');
    expect(
      metadata.plaintextSha256,
      sha256Hex('second, from the phone'),
      reason: 'the rename must not restore the old content hash',
    );
    expect(await h.serverContent(entry.node.id), 'second, from the phone');
    expect(h.engine.pendingOperations.hasUnfinishedOperations, isFalse);
    expect(h.engine.conflicts.open, isEmpty);
  });

  test('a move queued before a remote rename keeps both changes', () async {
    final h = await ConflictHarness.create();
    expect(await h.files.createFolder('Archive'), isTrue);
    await h.engine.runOnce();
    final entry = await h.uploadRootFile('notes.txt', 'content');
    final archive = h.files.entries.singleWhere((e) => e.isDirectory);
    h.engine.pause();
    expect(
      await h.files.renameNode(
        entry,
        entry.name,
        move: true,
        newParentId: archive.node.id,
      ),
      isTrue,
    );
    await h.remoteRename(entry.node.id, 'meeting notes.txt');

    h.engine.resume();
    await h.engine.runOnce();

    final node = await h.serverConnection.api!.getNode(
      h.serverConnection.session!.accessToken,
      entry.node.id,
    );
    expect(node.parentId, archive.node.id);
    expect(
      (await h.serverMetadata(entry.node.id)).fileName,
      'meeting notes.txt',
    );
    expect(h.engine.conflicts.open, isEmpty);
  });

  test(
    'two different renames keep the server name and report the conflict',
    () async {
      final h = await ConflictHarness.create();
      final entry = await h.uploadRootFile('photo.jpg', 'pixels');
      h.engine.pause();
      expect(await h.files.renameNode(entry, 'beach.jpg'), isTrue);
      await h.remoteRename(entry.node.id, 'holiday.jpg');

      h.engine.resume();
      await h.engine.runOnce();

      expect((await h.serverMetadata(entry.node.id)).fileName, 'holiday.jpg');
      await h.files.refresh();
      expect(h.files.entries.single.name, 'holiday.jpg');
      final conflict = h.engine.conflicts.open.single;
      expect(conflict.kind, SyncConflictKind.renameRejected);
      expect(conflict.fileName, 'beach.jpg');
      expect(conflict.nodeId, entry.node.id);
      expect(h.engine.pendingOperations.hasUnfinishedOperations, isFalse);
    },
  );

  test('a delete never removes an item changed on another device', () async {
    final h = await ConflictHarness.create();
    final entry = await h.uploadRootFile('plan.md', 'v1');
    h.engine.pause();
    expect(await h.files.deleteNode(entry), isTrue);
    expect(h.files.entries, isEmpty);
    await h.remoteReplaceContent(entry.node.id, 'v2 with new ideas');

    h.engine.resume();
    await h.engine.runOnce();

    final node = await h.serverConnection.api!.getNode(
      h.serverConnection.session!.accessToken,
      entry.node.id,
    );
    expect(node.isDeleted, isFalse);
    await h.files.refresh();
    expect(h.files.entries.single.name, 'plan.md');
    final conflict = h.engine.conflicts.open.single;
    expect(conflict.kind, SyncConflictKind.deleteRejected);
    expect(conflict.fileName, 'plan.md');
    expect(h.engine.pendingOperations.hasUnfinishedOperations, isFalse);
  });

  test(
    'a delete of an item already deleted elsewhere settles without a conflict',
    () async {
      final h = await ConflictHarness.create();
      final entry = await h.uploadRootFile('old.log', 'noise');
      h.engine.pause();
      expect(await h.files.deleteNode(entry), isTrue);
      final api = h.serverConnection.api!;
      final token = h.serverConnection.session!.accessToken;
      final node = await api.getNode(token, entry.node.id);
      await api.deleteNode(
        token,
        entry.node.id,
        operationId: '11111111-1111-4111-8111-111111111111',
        expectedRevision: node.revision,
      );

      h.engine.resume();
      await h.engine.runOnce();

      expect(h.engine.conflicts.open, isEmpty);
      expect(h.engine.pendingOperations.hasUnfinishedOperations, isFalse);
      expect(h.engine.nodeCache.getById(entry.node.id)!.isDeleted, isTrue);
    },
  );

  test(
    'marking a conflict copy resolved clears only its conflict marker',
    () async {
      final h = await ConflictHarness.create();
      final entry = await h.uploadRootFile('note.txt', 'one');
      await h.materializer.materialize(h.root.path);
      await File('${h.root.path}/note.txt').writeAsString('local edit');
      await h.remoteReplaceContent(entry.node.id, 'remote edit');
      await h.engine.runOnce();
      await h.materializer.materialize(h.root.path);
      await h.uploader.scan(h.root.path);
      await h.files.refresh();
      final copy = h.files.entries.singleWhere((e) => e.isConflictCopy);
      final before = await h.serverMetadata(copy.node.id);
      expect(before.conflictDetails, isNotNull);

      expect(await h.files.markConflictResolved(copy), isTrue);
      await h.engine.runOnce();

      final after = await h.serverMetadata(copy.node.id);
      expect(after.conflictDetails, isNull);
      expect(after.fileName, before.fileName);
      expect(after.plaintextSha256, before.plaintextSha256);
      await h.files.refresh();
      expect(h.files.entries.where((e) => e.isConflictCopy), isEmpty);
      expect(await h.serverContent(copy.node.id), 'local edit');
    },
  );
}
