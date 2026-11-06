import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/storage/search_index.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/files/files_controller.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/sync/sync_engine.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../support/memory_vault_key_storage.dart';
import '../sync/fake_node_server.dart';

Future<(FakeNodeServer, SyncEngine, FilesController)> _setUp() async {
  final fake = FakeNodeServer();
  final server = await fake.start();
  addTearDown(() => server.close(force: true));
  final connection = ServerConnectionController(
    deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
    serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
    sessionStore: SessionStore(MemorySessionStorage()),
  );
  addTearDown(connection.dispose);
  await connection.discover('127.0.0.1:${server.port}');
  await connection.confirmTrust();
  await connection.login('admin', 'correct horse battery staple');
  final vault = VaultKeyStore(MemoryVaultKeyStorage());
  (await vault.createVault(userId: FakeNodeServer.userId)).destroy();
  final engine = SyncEngine(
    serverConnection: connection,
    localDatabase: LocalDatabase.openInMemory(),
  );
  addTearDown(engine.dispose);
  final files = FilesController(
    serverConnection: connection,
    vaultKeyStore: vault,
    syncEngine: engine,
  );
  addTearDown(files.dispose);
  return (fake, engine, files);
}

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

Future<String> _localFile(String name, [String? content]) async {
  final dir = await _tempDir('homebox_bulk_src_');
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(content ?? name);
  return file.path;
}

FileEntry _named(FilesController files, String name) =>
    files.entries.firstWhere((entry) => entry.name == name);

/// Root: folder "Docs" with "Docs/inner.txt" and an empty "Docs/Empty",
/// plus "top.txt".
Future<void> _seedTree(SyncEngine engine, FilesController files) async {
  expect(await files.createFolder('Docs'), isTrue);
  await engine.runOnce();
  await files.refresh();
  files.openFolder(_named(files, 'Docs'));
  await files.refresh();
  expect(
    await files.uploadFile(await _localFile('inner.txt', 'inner')),
    isTrue,
  );
  expect(await files.createFolder('Empty'), isTrue);
  await engine.runOnce();
  files.goToRoot();
  await files.refresh();
  expect(await files.uploadFile(await _localFile('top.txt', 'top')), isTrue);
}

void main() {
  test(
    'bulk move puts entries into another folder and keeps the rest',
    () async {
      final (fake, engine, files) = await _setUp();
      expect(await files.createFolder('Target'), isTrue);
      expect(await files.createFolder('Box'), isTrue);
      await engine.runOnce();
      await files.refresh();
      for (final name in ['a.txt', 'b.txt']) {
        expect(await files.uploadFile(await _localFile(name)), isTrue);
      }
      final target = _named(files, 'Target');
      // A same-named file is already in the destination.
      files.openFolder(target);
      await files.refresh();
      expect(
        await files.uploadFile(await _localFile('b.txt', 'other')),
        isTrue,
      );
      files.goToRoot();
      await files.refresh();

      final choices = await files.folderChoices(null);
      expect(choices.map((c) => c.name), ['Box', 'Target']);

      final moving = [
        _named(files, 'a.txt'),
        _named(files, 'b.txt'),
        _named(files, 'Box'),
      ];
      expect(await files.moveNodes(moving, target.node.id), 2);
      expect(files.errorMessage, contains('already exists'));
      expect(files.entries.map((e) => e.name), ['Target', 'b.txt']);
      await engine.runOnce();
      expect(fake.nodeJson(moving[0].node.id)!['parentId'], target.node.id);
      expect(fake.nodeJson(moving[2].node.id)!['parentId'], target.node.id);
      expect(fake.nodeJson(moving[1].node.id)!['parentId'], isNull);

      // A folder cannot be moved into its own subtree.
      final box = moving[2];
      expect(await files.moveNodes([target], box.node.id), 0);
      expect(files.errorMessage, contains('into itself'));
    },
  );

  test('bulk download keeps the folder structure or builds one ZIP', () async {
    final (_, engine, files) = await _setUp();
    await _seedTree(engine, files);
    final selection = [_named(files, 'Docs'), _named(files, 'top.txt')];

    final out = await _tempDir('homebox_bulk_out_');
    // An existing name in the destination is never overwritten.
    await File('${out.path}${Platform.pathSeparator}top.txt')
        .writeAsString('mine');
    expect(await files.downloadEntries(selection, directory: out.path), 2);
    String read(String relative) => File(
      '${out.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    ).readAsStringSync();
    expect(read('Docs/inner.txt'), 'inner');
    expect(Directory('${out.path}/Docs/Empty').existsSync(), isTrue);
    expect(read('top.txt'), 'mine');
    expect(read('top (2).txt'), 'top');

    final zipPath = '${out.path}${Platform.pathSeparator}all.zip';
    expect(await files.downloadEntries(selection, zipPath: zipPath), 2);
    final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    final contents = {
      for (final file in archive.files)
        if (file.isFile) file.name: String.fromCharCodes(file.content),
    };
    expect(contents, {'Docs/inner.txt': 'inner', 'top.txt': 'top'});
    // No temporary plaintext or partial archive is left behind.
    expect(
      out
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .toSet(),
      {'Docs', 'top.txt', 'top (2).txt', 'all.zip'},
    );
  });

  test(
    'Trash restores and permanently deletes several items at once',
    () async {
      final (fake, engine, files) = await _setUp();
      await _seedTree(engine, files);
      final docs = _named(files, 'Docs');
      final top = _named(files, 'top.txt');
      expect(await files.deleteNodes([docs, top]), 2);
      await engine.runOnce();

      var trash = await files.trashEntries();
      expect(trash.map((t) => t.entry.name).toSet(), {'Docs', 'top.txt'});
      expect(await files.restoreEntries(trash), 2);
      await engine.runOnce();
      await files.refresh();
      expect(files.entries.map((e) => e.name), ['Docs', 'top.txt']);

      expect(
        await files.deleteNodes([
          _named(files, 'Docs'),
          _named(files, 'top.txt'),
        ]),
        2,
      );
      await engine.runOnce();
      trash = await files.trashEntries();
      final innerId = engine.nodeCache.listChildren(docs.node.id).first.id;
      expect(
        await files.purgeEntries([for (final t in trash) t.entry]),
        2,
        reason: "${trash.map((t) => t.entry.name)} ${files.errorMessage}",
      );
      expect(await files.trashEntries(), isEmpty);
      // The folder's content is gone from this device and the server.
      expect(engine.nodeCache.getById(innerId), isNull);
      expect(fake.nodeJson(docs.node.id), isNull);
      expect(fake.nodeJson(innerId), isNull);
      expect(fake.nodeJson(top.node.id), isNull);
    },
  );

  test('favorites are marked, listed with their folder, and synced', () async {
    final (fake, engine, files) = await _setUp();
    await _seedTree(engine, files);
    final docs = _named(files, 'Docs');
    files.openFolder(docs);
    await files.refresh();
    final inner = _named(files, 'inner.txt');
    expect(await files.setFavorite([inner], true), 1);
    expect(files.isFavorite(inner), isTrue);
    files.goToRoot();
    await files.refresh();
    expect(await files.setFavorite([_named(files, 'Docs')], true), 1);
    expect(fake.favoriteIds, {inner.node.id, docs.node.id});

    final favorites = await files.favoriteEntries();
    expect(
      {for (final f in favorites) f.entry.name: f.location},
      {'Docs': '', 'inner.txt': 'Docs'},
    );

    // Another device removed one; the next sync pass follows.
    fake.favoriteIds.remove(docs.node.id);
    await engine.runOnce();
    await files.refresh();
    expect(files.isFavorite(_named(files, 'Docs')), isFalse);

    // Opening a favorite's folder shows the full path.
    await files.revealFolder(inner.node.parentId);
    expect(files.breadcrumbNames, ['Docs']);
    expect(files.entries.map((e) => e.name), contains('inner.txt'));
  });

  test('search finds parts of names in any language and skips Trash', () async {
    final (_, engine, files) = await _setUp();
    await _seedTree(engine, files);
    expect(
      await files.uploadFile(await _localFile('Отчёт за март.pdf')),
      isTrue,
    );

    Future<List<String>> names(String query) async => [
      for (final hit in await files.search(query)) hit.entry.name,
    ];
    expect(await names('ОТЧ'), ['Отчёт за март.pdf']);
    expect(await names('март отч'), ['Отчёт за март.pdf']);
    expect(await names('nner'), ['inner.txt']);
    expect(await names('mp'), ['Empty'], reason: 'two letters use LIKE');
    final hit = (await files.search('inner')).single;
    expect(hit.location, 'Docs');
    expect(await names('   '), isEmpty);

    // A folder in Trash hides everything inside it.
    expect(await files.deleteNodes([_named(files, 'Docs')]), 1);
    expect(await names('inner'), isEmpty);

    // Renames are picked up incrementally.
    final report = _named(files, 'Отчёт за март.pdf');
    expect(await files.renameNode(report, 'Report.pdf'), isTrue);
    expect(await names('март'), isEmpty);
    expect(await names('report'), ['Report.pdf']);
  });

  test('the search index escapes LIKE wildcards and FTS quotes', () {
    final index = SearchIndex();
    addTearDown(index.dispose);
    index.batch(() {
      index.put('1', 'a', '100%_done.txt');
      index.put('2', 'b', '1000 done.txt');
      index.put('3', 'c', 'say "hi".txt');
    });
    expect(index.search('%_'), ['1']);
    expect(index.search('"hi"'), ['3']);
    index.remove('1');
    expect(index.search('%_'), isEmpty);
    expect(index.stamps().keys.toSet(), {'2', '3'});
  });
}
