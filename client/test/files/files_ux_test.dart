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

Future<(SyncEngine, FilesController)> _setUp() async {
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
  return (engine, files);
}

Future<String> _localFile(String name) async {
  final dir = await Directory.systemTemp.createTemp('homebox_ux_src_');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(name);
  return file.path;
}

List<String> _names(Iterable<FileEntry> entries) =>
    entries.map((entry) => entry.name).toList();

void main() {
  test('Shift+click selects the range from the last toggled entry', () async {
    final (_, files) = await _setUp();
    for (final name in ['a.txt', 'b.txt', 'c.txt', 'd.txt']) {
      expect(await files.uploadFile(await _localFile(name)), isTrue);
    }
    files.setSort(FileListSort.name);
    FileEntry named(String name) =>
        files.entries.firstWhere((entry) => entry.name == name);

    files.extendSelectionTo(named('b.txt'));
    expect(_names(files.selectedEntries), ['b.txt']);

    files.extendSelectionTo(named('d.txt'));
    expect(_names(files.selectedEntries), ['b.txt', 'c.txt', 'd.txt']);

    files.clearSelection();
    files.toggleSelection(named('d.txt'));
    files.extendSelectionTo(named('a.txt'));
    expect(_names(files.selectedEntries), ['a.txt', 'b.txt', 'c.txt', 'd.txt']);
    expect(files.selectionMode, isTrue);
  });

  test('an upload can be stored under a different name', () async {
    final (_, files) = await _setUp();
    final path = await _localFile('photo.jpg');

    final result = await files.uploadFiles(
      [path],
      fileNames: {path: 'photo (1).jpg'},
    );

    expect(result.succeeded, 1);
    expect(_names(files.entries), ['photo (1).jpg']);
  });

  test('moving to Trash can be undone by restoring the same entries', () async {
    final (engine, files) = await _setUp();
    expect(await files.createFolder('Docs'), isTrue);
    expect(await files.uploadFile(await _localFile('note.txt')), isTrue);
    await engine.runOnce();
    await files.refresh();
    final entries = List.of(files.entries);

    expect(await files.deleteNodes(entries), 2);
    expect(files.entries, isEmpty);

    for (final entry in entries) {
      expect(await files.restoreFromTrash(entry), isTrue);
    }
    await engine.runOnce();
    await files.refresh();
    expect(_names(files.entries)..sort(), ['Docs', 'note.txt']);
    expect(await files.trashEntries(), isEmpty);
  });

  test('the sync engine reports waiting changes and its last sync', () async {
    final (engine, files) = await _setUp();
    expect(engine.lastSyncedAt, isNull);

    expect(await files.createFolder('Queued'), isTrue);
    expect(engine.pendingChangeCount, 1);

    await engine.runOnce();
    expect(engine.pendingChangeCount, 0);
    expect(engine.lastSyncedAt, isNotNull);
  });
}
