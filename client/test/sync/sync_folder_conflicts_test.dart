import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/sync_conflicts_store.dart';
import 'package:homebox_client/features/syncfolder/local_folder_uploader.dart';
import 'package:homebox_client/features/syncfolder/sync_folder_materializer.dart';

import 'conflict_test_harness.dart';

/// Spec §21 for the local sync folder: a pass may replace or remove a local
/// file only when it provably holds what this device last synced; anything
/// else survives as a conflict copy that is then uploaded.
void main() {
  test('a remote update never overwrites a local edit: the edit becomes an uploaded conflict copy', () async {
    final h = await ConflictHarness.create();
    final entry = await h.uploadRootFile('note.txt', 'version one');
    await h.materializer.materialize(h.root.path);
    final local = File('${h.root.path}/note.txt');
    expect(await local.readAsString(), 'version one');

    await local.writeAsString('edited on this computer');
    await h.remoteReplaceContent(entry.node.id, 'edited on the phone');
    await h.engine.runOnce();

    await h.materializer.materialize(h.root.path);
    expect(
      h.materializer.status,
      SyncFolderStatus.idle,
      reason: h.materializer.errorMessage,
    );
    expect(await local.readAsString(), 'edited on the phone');
    final names = await h.rootFileNames();
    final copyName = names.singleWhere(
      (name) => conflictCopyPattern('note', '.txt').hasMatch(name),
    );
    expect(
      await File('${h.root.path}/$copyName').readAsString(),
      'edited on this computer',
    );
    final conflict = h.engine.conflicts.open.single;
    expect(conflict.kind, SyncConflictKind.bothModified);
    expect(conflict.fileName, 'note.txt');
    expect(conflict.conflictCopyPath, copyName);

    await h.uploader.scan(h.root.path);
    expect(
      h.uploader.status,
      LocalUploadStatus.idle,
      reason: h.uploader.errorMessage,
    );
    await h.files.refresh();
    final copy = h.files.entries.singleWhere((e) => e.name == copyName);
    expect(copy.isConflictCopy, isTrue);
    expect(copy.metadata.conflictDetails, contains('"note.txt"'));
    expect(copy.metadata.conflictDetails, contains(conflictTestDeviceName));
    expect(await h.serverContent(copy.node.id), 'edited on this computer');
    expect(await h.serverContent(entry.node.id), 'edited on the phone');
    expect(h.engine.conflicts.copyAwaitingUpload(copyName), isNull);
  });

  test(
    'an untouched local copy is simply replaced by a remote update',
    () async {
      final h = await ConflictHarness.create();
      final entry = await h.uploadRootFile('note.txt', 'version one');
      await h.materializer.materialize(h.root.path);

      await h.remoteReplaceContent(entry.node.id, 'version two');
      await h.engine.runOnce();
      await h.materializer.materialize(h.root.path);

      expect(await h.rootFileNames(), ['note.txt']);
      expect(
        await File('${h.root.path}/note.txt').readAsString(),
        'version two',
      );
      expect(h.engine.conflicts.open, isEmpty);
    },
  );

  test(
    'a file deleted on another device keeps the local edit as a conflict copy',
    () async {
      final h = await ConflictHarness.create();
      final entry = await h.uploadRootFile('report.docx', 'draft');
      await h.materializer.materialize(h.root.path);
      await File('${h.root.path}/report.docx').writeAsString('final wording');

      expect(await h.files.deleteNode(entry), isTrue);
      await h.engine.runOnce();
      await h.materializer.materialize(h.root.path);

      final names = await h.rootFileNames();
      expect(names, isNot(contains('report.docx')));
      final copyName = names.single;
      expect(conflictCopyPattern('report', '.docx').hasMatch(copyName), isTrue);
      expect(
        await File('${h.root.path}/$copyName').readAsString(),
        'final wording',
      );
      expect(
        h.engine.conflicts.open.single.kind,
        SyncConflictKind.modifiedLocallyDeletedRemotely,
      );

      await h.uploader.scan(h.root.path);
      await h.files.refresh();
      final restored = h.files.entries.single;
      expect(restored.name, copyName);
      expect(restored.isConflictCopy, isTrue);
      expect(await h.serverContent(restored.node.id), 'final wording');
    },
  );

  test(
    'a local file and a different server file with the same name are both kept',
    () async {
      final h = await ConflictHarness.create();
      await File('${h.root.path}/shared.txt').writeAsString('made on this pc');
      final remote = await h.uploadRootFile('shared.txt', 'made elsewhere');

      await h.materializer.materialize(h.root.path);

      expect(
        await File('${h.root.path}/shared.txt').readAsString(),
        'made elsewhere',
      );
      final copyName = (await h.rootFileNames()).singleWhere(
        (name) => name != 'shared.txt',
      );
      expect(conflictCopyPattern('shared', '.txt').hasMatch(copyName), isTrue);
      expect(
        await File('${h.root.path}/$copyName').readAsString(),
        'made on this pc',
      );
      expect(h.engine.conflicts.open.single.kind, SyncConflictKind.bothCreated);
      expect(await h.serverContent(remote.node.id), 'made elsewhere');
    },
  );

  test('scan keeps a local edit made on an older version instead of overwriting the newer server version', () async {
    final h = await ConflictHarness.create();
    final entry = await h.uploadRootFile('budget.xlsx', 'v1');
    await h.materializer.materialize(h.root.path);
    await File('${h.root.path}/budget.xlsx').writeAsString('local numbers');
    // The pull already knows about v2, but no materialize pass ran yet: the
    // watcher's local-change pass scans first.
    await h.remoteReplaceContent(entry.node.id, 'v2 from the laptop');
    await h.engine.runOnce();

    await h.uploader.scan(h.root.path);
    expect(
      h.uploader.status,
      LocalUploadStatus.idle,
      reason: h.uploader.errorMessage,
    );

    expect(await h.serverContent(entry.node.id), 'v2 from the laptop');
    await h.files.refresh();
    final copy = h.files.entries.singleWhere((e) => e.isConflictCopy);
    expect(conflictCopyPattern('budget', '.xlsx').hasMatch(copy.name), isTrue);
    expect(await h.serverContent(copy.node.id), 'local numbers');
    expect(h.engine.conflicts.open.single.kind, SyncConflictKind.bothModified);

    await h.materializer.materialize(h.root.path);
    expect(
      await File('${h.root.path}/budget.xlsx').readAsString(),
      'v2 from the laptop',
    );
    expect(
      await File('${h.root.path}/${copy.name}').readAsString(),
      'local numbers',
    );
  });

  test('an edit made before a remote rename moves with the file and is still uploaded', () async {
    final h = await ConflictHarness.create();
    final entry = await h.uploadRootFile('todo.txt', 'buy milk');
    await h.materializer.materialize(h.root.path);
    await File('${h.root.path}/todo.txt').writeAsString('buy milk and bread');

    await h.remoteRename(entry.node.id, 'shopping.txt');
    await h.engine.runOnce();
    await h.materializer.materialize(h.root.path);

    expect(await h.rootFileNames(), ['shopping.txt']);
    expect(
      await File('${h.root.path}/shopping.txt').readAsString(),
      'buy milk and bread',
    );
    await h.uploader.scan(h.root.path);
    expect(await h.serverContent(entry.node.id), 'buy milk and bread');
    expect((await h.serverMetadata(entry.node.id)).fileName, 'shopping.txt');
    expect(h.engine.conflicts.open, isEmpty);
  });

  test('two files that swapped names remotely are relocated without conflict copies', () async {
    final h = await ConflictHarness.create();
    final a = await h.uploadRootFile('a.txt', 'alpha');
    final b = await h.uploadRootFile('b.txt', 'bravo');
    await h.materializer.materialize(h.root.path);

    await h.remoteRename(a.node.id, 'tmp.txt');
    await h.remoteRename(b.node.id, 'a.txt');
    await h.remoteRename(a.node.id, 'b.txt');
    await h.engine.runOnce();
    await h.materializer.materialize(h.root.path);
    await h.materializer.materialize(h.root.path);

    expect(await h.rootFileNames(), ['a.txt', 'b.txt']);
    expect(await File('${h.root.path}/a.txt').readAsString(), 'bravo');
    expect(await File('${h.root.path}/b.txt').readAsString(), 'alpha');
    expect(h.engine.conflicts.open, isEmpty);
  });

  test(
    'a case-only remote rename relocates the file without a conflict copy',
    () async {
      final h = await ConflictHarness.create();
      final entry = await h.uploadRootFile('readme.md', 'hello');
      await h.materializer.materialize(h.root.path);

      await h.remoteRename(entry.node.id, 'README.md');
      await h.engine.runOnce();
      await h.materializer.materialize(h.root.path);

      expect(
        h.materializer.status,
        SyncFolderStatus.idle,
        reason: h.materializer.errorMessage,
      );
      expect(await h.rootFileNames(), ['README.md']);
      expect(await File('${h.root.path}/README.md').readAsString(), 'hello');
      expect(h.engine.conflicts.open, isEmpty);
    },
  );
}
