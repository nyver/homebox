import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/storage/local_database.dart';
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

Future<String> _localFile(String name) async {
  final dir = await Directory.systemTemp.createTemp('homebox_bulk_');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(name);
  return file.path;
}

FileEntry _named(FilesController files, String name) =>
    files.entries.firstWhere((entry) => entry.name == name);

void main() {
  test(
    'bulk move to trash hides files and folders at once and syncs them all',
    () async {
      final (fake, engine, files) = await _setUp();
      expect(await files.createFolder('Photos'), isTrue);
      await engine.runOnce();
      await files.refresh();
      files.openFolder(_named(files, 'Photos'));
      await files.refresh();
      expect(await files.uploadFile(await _localFile('inside.jpg')), isTrue);
      final insideId = files.entries.single.node.id;
      files.goToRoot();
      await files.refresh();
      for (final name in ['a.txt', 'b.txt', 'keep.txt']) {
        expect(await files.uploadFile(await _localFile(name)), isTrue);
      }

      files
        ..toggleSelection(_named(files, 'Photos'))
        ..toggleSelection(_named(files, 'a.txt'))
        ..toggleSelection(_named(files, 'b.txt'));
      expect(files.selectionMode, isTrue);
      expect(files.selectedCount, 3);
      final selected = files.selectedEntries;
      final selectedIds = [for (final e in selected) e.node.id];

      expect(await files.deleteNodes(selected), 3);
      // Applied locally right away, offline-first like a single delete.
      expect(files.entries.map((e) => e.name), ['keep.txt']);
      expect(files.selectionMode, isFalse);
      expect(files.selectedCount, 0);

      await engine.runOnce();
      for (final id in selectedIds) {
        expect(fake.nodeJson(id)!['deletedAt'], isNotNull, reason: id);
      }
      expect(
        fake.nodeJson(_named(files, 'keep.txt').node.id)!['deletedAt'],
        isNull,
      );
      // The folder's content went to Trash with it, not as its own entry,
      // so restoring the folder brings it back.
      expect(fake.nodeJson(insideId)!['deletedAt'], isNull);
      expect(engine.pendingOperations.hasUnfinishedOperations, isFalse);
    },
  );

  test(
    'an entry inside another selected folder is not deleted separately',
    () async {
      final (fake, engine, files) = await _setUp();
      expect(await files.createFolder('Outer'), isTrue);
      await engine.runOnce();
      await files.refresh();
      final outer = _named(files, 'Outer');
      files.openFolder(outer);
      await files.refresh();
      expect(await files.uploadFile(await _localFile('child.txt')), isTrue);
      final child = files.entries.single;

      expect(await files.deleteNodes([outer, child]), 1);
      await engine.runOnce();
      expect(fake.nodeJson(outer.node.id)!['deletedAt'], isNotNull);
      expect(fake.nodeJson(child.node.id)!['deletedAt'], isNull);
    },
  );

  test('selection follows the open folder and its current entries', () async {
    final (fake, engine, files) = await _setUp();
    expect(await files.createFolder('Docs'), isTrue);
    await engine.runOnce();
    await files.refresh();
    for (final name in ['one.txt', 'two.txt']) {
      expect(await files.uploadFile(await _localFile(name)), isTrue);
    }

    files.toggleSelectAll();
    expect(files.selectedCount, 3);
    files.toggleSelectAll();
    expect(files.selectedCount, 0);
    expect(files.selectionMode, isTrue, reason: 'still selecting, just empty');

    files.toggleSelection(_named(files, 'one.txt'));
    files.toggleSelection(_named(files, 'one.txt'));
    expect(files.selectedCount, 0);

    // An entry deleted on another device leaves the selection.
    files.toggleSelection(_named(files, 'two.txt'));
    fake.remoteDelete(_named(files, 'two.txt').node.id);
    await engine.runOnce();
    await files.refresh();
    expect(files.selectedCount, 0);

    // Navigating drops the selection entirely.
    files.toggleSelection(_named(files, 'one.txt'));
    files.openFolder(_named(files, 'Docs'));
    expect(files.selectionMode, isFalse);
    expect(files.selectedCount, 0);

    files.startSelection();
    expect(files.selectionMode, isTrue);
    files.clearSelection();
    expect(files.selectionMode, isFalse);
  });
}
