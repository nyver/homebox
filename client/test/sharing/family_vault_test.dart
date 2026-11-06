import 'dart:convert';

import 'package:archive/archive_io.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/account_identity.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/key_ring.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/storage/folder_keys_store.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/transport/homebox_api_client.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/files/files_controller.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/sharing/family_vault_controller.dart';
import 'package:homebox_client/features/sharing/shared_folder_browser.dart';
import 'package:homebox_client/features/sync/sync_engine.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../support/memory_vault_key_storage.dart';
import '../sync/fake_node_server.dart';

/// One signed-in account with its own device, vault, and local database.
final class _Account {
  _Account({
    required this.userId,
    required this.devices,
    required this.connection,
    required this.vault,
    required this.engine,
    required this.files,
    required this.family,
  });

  final String userId;
  final DeviceIdentityStore devices;
  final ServerConnectionController connection;
  final VaultKeyStore vault;
  final SyncEngine engine;
  final FilesController files;
  final FamilyVaultController family;
}

Future<_Account> _signIn(
  HttpServer server,
  String username,
  String userId,
) async {
  final devices = DeviceIdentityStore(MemoryDevicePrivateKeyStorage());
  final connection = ServerConnectionController(
    deviceIdentityStore: devices,
    serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
    sessionStore: SessionStore(MemorySessionStorage()),
  );
  addTearDown(connection.dispose);
  await connection.discover('127.0.0.1:${server.port}');
  await connection.confirmTrust();
  await connection.login(username, 'correct horse battery staple');
  expect(connection.status, ServerConnectionStatus.authenticated);
  final vault = VaultKeyStore(MemoryVaultKeyStorage());
  (await vault.createVault(userId: userId)).destroy();
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
  final family = FamilyVaultController(
    serverConnection: connection,
    vaultKeyStore: vault,
    deviceIdentityStore: devices,
    syncEngine: engine,
  );
  addTearDown(family.dispose);
  return _Account(
    userId: userId,
    devices: devices,
    connection: connection,
    vault: vault,
    engine: engine,
    files: files,
    family: family,
  );
}

/// Publishes the member's device with a certificate from its own account
/// identity, as the real server would after the member set up its vault.
Future<void> _publishMemberDevice(
  FakeNodeServer server,
  _Account member,
) async {
  final device = (await member.devices.load())!;
  final identity = await AccountIdentity.derive(
    vaultKey: (await member.vault.loadVaultKey())!,
    accountId: member.userId,
  );
  final certificate = await identity.certifyDevice(
    accountId: member.userId,
    deviceId: server.memberDeviceId!,
    deviceKeyVersion: 1,
    devicePublicKey: device.publicKey.bytes,
  );
  server.memberShareDevices = [
    {
      'id': server.memberDeviceId,
      'platform': 'WINDOWS',
      'publicKey': base64Encode(device.publicKey.bytes),
      'keyVersion': 1,
      'signatureVersion': certificate.signatureVersion,
      'accountIdentityPublicKey': base64Encode(
        certificate.accountIdentityPublicKey,
      ),
      'publicKeySignature': base64Encode(certificate.signature),
    },
  ];
}

Future<File> _tempFile(String name, String content) async {
  final dir = await Directory.systemTemp.createTemp('homebox_family_');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(content);
  return file;
}

Future<String> _tempPath(String name) async {
  final dir = await Directory.systemTemp.createTemp('homebox_family_out_');
  addTearDown(() => dir.delete(recursive: true));
  return '${dir.path}${Platform.pathSeparator}$name';
}

void main() {
  test('an owner shares a folder, the member verifies, reads, and writes it, '
      'and removing the member rotates the folder key', () async {
    final fake = FakeNodeServer();
    final server = await fake.start();
    addTearDown(() => server.close(force: true));
    final owner = await _signIn(server, 'admin', FakeNodeServer.userId);
    final member = await _signIn(server, 'member', FakeNodeServer.memberId);
    await _publishMemberDevice(fake, member);

    // The owner's folder starts out in the personal Vault.
    expect(await owner.files.createFolder('Family'), isTrue);
    await owner.engine.runOnce();
    await owner.files.refresh();
    final folder = owner.files.entries.single;
    owner.files.openFolder(folder);
    await owner.files.refresh();
    final note = await _tempFile('note.txt', 'shared family note');
    expect(await owner.files.uploadFile(note.path), isTrue);
    final noteId = owner.files.entries.single.node.id;
    expect(fake.nodeJson(noteId)!['metadataKeyScopeId'], owner.userId);

    // Look up the member; its fingerprint is what the member sees.
    await member.family.refresh();
    final candidate = await owner.family.lookupRecipient(member.userId);
    expect(candidate, isNotNull, reason: owner.family.errorMessage);
    expect(candidate!.alreadyTrusted, isFalse);
    expect(candidate.fingerprint, member.family.accountFingerprint);

    expect(
      await owner.family.shareFolder(
        folderId: folder.node.id,
        candidate: candidate,
        permission: SharePermission.readWrite,
      ),
      isTrue,
      reason: owner.family.errorMessage,
    );
    // The whole subtree moved to the folder's own key; nothing the member
    // receives can open the owner's personal Vault.
    expect(
      fake.nodeJson(folder.node.id)!['metadataKeyScopeId'],
      folder.node.id,
    );
    expect(fake.nodeJson(noteId)!['metadataKeyScopeId'], folder.node.id);
    expect(fake.fileVersionsOf(noteId).single['keyScopeId'], folder.node.id);
    expect(owner.family.isShared(folder.node.id), isTrue);
    final envelope =
        (fake.shares.single['envelopes'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(envelope['targetDeviceId'], fake.memberDeviceId);
    expect(envelope['ownerSignature'], isNotNull);

    // The member must compare the owner's fingerprint before opening.
    await member.family.refresh();
    final incoming = member.family.incoming.single;
    expect(incoming.state, IncomingShareState.unverified);
    await owner.family.refresh();
    expect(incoming.ownerFingerprint, owner.family.accountFingerprint);
    await member.family.trustOwner(incoming);
    final ready = member.family.incoming.single;
    expect(ready.state, IncomingShareState.ready);
    expect(ready.folderName, 'Family');

    final browser = (await member.family.open(ready))!;
    addTearDown(browser.dispose);
    await browser.refresh();
    expect(browser.entries.map((e) => e.name), ['note.txt']);
    final downloaded = await _tempPath('note.txt');
    expect(await browser.download(browser.entries.single, downloaded), isTrue);
    expect(await File(downloaded).readAsString(), 'shared family note');

    // READ_WRITE: the member adds a file, which the owner can read.
    final reply = await _tempFile('reply.txt', 'written by the member');
    expect(
      await browser.uploadFiles([reply.path]),
      isTrue,
      reason: browser.errorMessage,
    );
    expect(browser.entries.map((e) => e.name), ['note.txt', 'reply.txt']);
    await owner.engine.runOnce();
    await owner.files.refresh();
    final replyEntry = owner.files.entries.firstWhere(
      (e) => e.name == 'reply.txt',
    );
    final ownerCopy = await _tempPath('reply.txt');
    expect(await owner.files.downloadFile(replyEntry, ownerCopy), isTrue);
    expect(await File(ownerCopy).readAsString(), 'written by the member');

    // Removing the member rotates the key; new content uses version 2.
    expect(
      await owner.family.revoke(owner.family.outgoing.single),
      isTrue,
      reason: owner.family.errorMessage,
    );
    expect(fake.folderKeys[folder.node.id], hasLength(2));
    expect(owner.family.outgoing, isEmpty);
    final later = await _tempFile('later.txt', 'after removal');
    expect(await owner.files.uploadFile(later.path), isTrue);
    final laterEntry = owner.files.entries.firstWhere(
      (e) => e.name == 'later.txt',
    );
    final laterVersion = fake.fileVersionsOf(laterEntry.node.id).single;
    expect(laterVersion['keyScopeId'], folder.node.id);
    expect(laterVersion['keyVersion'], 2);
    await member.family.refresh();
    expect(member.family.incoming, isEmpty);
  });

  test('a member whose identity changed is refused', () async {
    final fake = FakeNodeServer();
    final server = await fake.start();
    addTearDown(() => server.close(force: true));
    final owner = await _signIn(server, 'admin', FakeNodeServer.userId);
    final member = await _signIn(server, 'member', FakeNodeServer.memberId);
    await _publishMemberDevice(fake, member);
    expect(await owner.files.createFolder('Family'), isTrue);
    await owner.engine.runOnce();
    await owner.files.refresh();
    final candidate = (await owner.family.lookupRecipient(member.userId))!;
    expect(
      await owner.family.shareFolder(
        folderId: owner.files.entries.single.node.id,
        candidate: candidate,
        permission: SharePermission.read,
      ),
      isTrue,
    );

    // A malicious server substitutes a device certified by another identity.
    final impostorVault = VaultKeyStore(MemoryVaultKeyStorage());
    (await impostorVault.createVault(userId: member.userId)).destroy();
    final impostor = await AccountIdentity.derive(
      vaultKey: (await impostorVault.loadVaultKey())!,
      accountId: member.userId,
    );
    final device = (await member.devices.load())!;
    final forged = await impostor.certifyDevice(
      accountId: member.userId,
      deviceId: fake.memberDeviceId!,
      deviceKeyVersion: 1,
      devicePublicKey: device.publicKey.bytes,
    );
    fake.memberShareDevices.single['accountIdentityPublicKey'] = base64Encode(
      forged.accountIdentityPublicKey,
    );
    fake.memberShareDevices.single['publicKeySignature'] = base64Encode(
      forged.signature,
    );
    expect(await owner.family.lookupRecipient(member.userId), isNull);
    expect(
      owner.family.errorMessage,
      contains('identity of this account changed'),
    );
  });

  test('a folder inside a shared folder cannot be shared', () async {
    final fake = FakeNodeServer();
    final server = await fake.start();
    addTearDown(() => server.close(force: true));
    final owner = await _signIn(server, 'admin', FakeNodeServer.userId);
    final member = await _signIn(server, 'member', FakeNodeServer.memberId);
    await _publishMemberDevice(fake, member);
    expect(await owner.files.createFolder('Outer'), isTrue);
    await owner.engine.runOnce();
    await owner.files.refresh();
    final outer = owner.files.entries.single;
    owner.files.openFolder(outer);
    await owner.files.refresh();
    expect(await owner.files.createFolder('Inner'), isTrue);
    await owner.engine.runOnce();
    await owner.files.refresh();
    final inner = owner.files.entries.single;
    expect(owner.family.canShare(inner.node), isTrue);

    final candidate = (await owner.family.lookupRecipient(member.userId))!;
    expect(
      await owner.family.shareFolder(
        folderId: outer.node.id,
        candidate: candidate,
        permission: SharePermission.read,
      ),
      isTrue,
    );
    // The inner folder joined the outer folder's key scope.
    expect(fake.nodeJson(inner.node.id)!['metadataKeyScopeId'], outer.node.id);
    expect(owner.family.canShare(inner.node), isFalse);
    expect(owner.family.canShare(outer.node), isTrue);

    // A new folder created inside the shared one goes straight to its key.
    expect(await owner.files.createFolder('Added later'), isTrue);
    await owner.engine.runOnce();
    await owner.files.refresh();
    final added = owner.files.entries.firstWhere(
      (e) => e.name == 'Added later',
    );
    expect(fake.nodeJson(added.node.id)!['metadataKeyScopeId'], outer.node.id);
  });

  test('removing a member rotates from the newest key on the server, delivers it to '
      'the remaining members first, and only then removes access', () async {
    final fake = FakeNodeServer();
    final server = await fake.start();
    addTearDown(() => server.close(force: true));
    final owner = await _signIn(server, 'admin', FakeNodeServer.userId);
    final member = await _signIn(server, 'member', FakeNodeServer.memberId);
    await _publishMemberDevice(fake, member);
    expect(await owner.files.createFolder('Family'), isTrue);
    await owner.engine.runOnce();
    await owner.files.refresh();
    final folderId = owner.files.entries.single.node.id;
    final candidate = (await owner.family.lookupRecipient(member.userId))!;
    expect(
      await owner.family.shareFolder(
        folderId: folderId,
        candidate: candidate,
        permission: SharePermission.read,
      ),
      isTrue,
    );
    // A second share of the same folder, standing in for another member
    // who stays: it must receive the new key before the removal.
    fake.shares.add({
      ...fake.shares.single,
      'id': 'share-2',
      'envelopes': <dynamic>[],
    });
    // Another owner device already rotated to version 2; this device's
    // local cache still knows only version 1.
    final vaultKey = (await owner.vault.loadVaultKey())!;
    final folderKey = newFolderKey();
    fake.folderKeys[folderId]!.add({
      'folderId': folderId,
      'keyVersion': 2,
      'ownerEnvelope': base64Encode(
        await wrapFolderKeyForOwner(
          vaultKey: vaultKey,
          folderKey: folderKey,
          folderId: folderId,
          ownerUserId: owner.userId,
          version: 2,
        ),
      ),
      'createdAt': '2026-01-01T00:00:00Z',
    });
    await owner.family.refresh();
    final removed = owner.family.outgoing.firstWhere(
      (view) => view.share.id == 'share-1',
    );
    expect(
      await owner.family.revoke(removed),
      isTrue,
      reason: owner.family.errorMessage,
    );
    expect(
      [for (final k in fake.folderKeys[folderId]!) k['keyVersion']],
      [1, 2, 3],
    );
    final remaining = fake.shares.firstWhere((s) => s['id'] == 'share-2');
    expect(remaining['revoked'], isFalse);
    expect(
      {
        for (final e in remaining['envelopes'] as List<dynamic>)
          (e as Map<String, dynamic>)['keyVersion'],
      },
      {1, 2, 3},
    );
    expect(
      fake.shares.firstWhere((s) => s['id'] == 'share-1')['revoked'],
      isTrue,
    );
  });

  test(
    'one item that cannot be re-encrypted does not block the rest',
    () async {
      final fake = FakeNodeServer();
      final server = await fake.start();
      addTearDown(() => server.close(force: true));
      final owner = await _signIn(server, 'admin', FakeNodeServer.userId);
      final member = await _signIn(server, 'member', FakeNodeServer.memberId);
      await _publishMemberDevice(fake, member);
      expect(await owner.files.createFolder('Family'), isTrue);
      await owner.engine.runOnce();
      await owner.files.refresh();
      final folder = owner.files.entries.single;
      owner.files.openFolder(folder);
      await owner.files.refresh();
      for (final name in ['broken.txt', 'fine.txt']) {
        expect(
          await owner.files.uploadFile((await _tempFile(name, name)).path),
          isTrue,
        );
      }
      final broken = owner.files.entries.firstWhere(
        (e) => e.name == 'broken.txt',
      );
      final fine = owner.files.entries.firstWhere((e) => e.name == 'fine.txt');
      fake.replaceMetadataWithUndecryptable(broken.node.id);
      await owner.engine.runOnce();

      final candidate = (await owner.family.lookupRecipient(member.userId))!;
      expect(
        await owner.family.shareFolder(
          folderId: folder.node.id,
          candidate: candidate,
          permission: SharePermission.read,
        ),
        isTrue,
        reason: owner.family.errorMessage,
      );
      expect(
        fake.nodeJson(fine.node.id)!['metadataKeyScopeId'],
        folder.node.id,
      );
      expect(
        fake.nodeJson(broken.node.id)!['metadataKeyScopeId'],
        owner.userId,
      );
      expect(owner.family.noticeMessage, contains('1 item(s)'));
    },
  );

  test('merging folder keys never drops a key this device just created', () {
    final database = LocalDatabase.openInMemory();
    addTearDown(database.dispose);
    final store = FolderKeysStore(database.db);
    store.add('folder', 2, Uint8List.fromList([2]));
    store.mergeAll([
      FolderKeyRecord(
        folderId: 'folder',
        keyVersion: 1,
        ownerEnvelope: Uint8List.fromList([1]),
      ),
    ]);
    expect(store.all()['folder']!.keys.toSet(), {1, 2});
  });

  test(
    'a member with edit rights moves, downloads, and trashes several items',
    () async {
      final fake = FakeNodeServer();
      final server = await fake.start();
      addTearDown(() => server.close(force: true));
      final owner = await _signIn(server, 'admin', FakeNodeServer.userId);
      final member = await _signIn(server, 'member', FakeNodeServer.memberId);
      await _publishMemberDevice(fake, member);
      expect(await owner.files.createFolder('Family'), isTrue);
      await owner.engine.runOnce();
      await owner.files.refresh();
      final folder = owner.files.entries.single;
      final candidate = (await owner.family.lookupRecipient(member.userId))!;
      expect(
        await owner.family.shareFolder(
          folderId: folder.node.id,
          candidate: candidate,
          permission: SharePermission.readWrite,
        ),
        isTrue,
      );
      await member.family.refresh();
      await member.family.trustOwner(member.family.incoming.single);
      final browser = (await member.family.open(
        member.family.incoming.single,
      ))!;
      addTearDown(browser.dispose);
      await browser.refresh();
      expect(await browser.createFolder('Sub'), isTrue);
      expect(
        await browser.uploadFiles([
          (await _tempFile('a.txt', 'A')).path,
          (await _tempFile('b.txt', 'B')).path,
        ]),
        isTrue,
      );
      SharedEntry named(String name) =>
          browser.entries.firstWhere((entry) => entry.name == name);

      browser
        ..toggleSelection(named('a.txt'))
        ..toggleSelection(named('b.txt'));
      expect(browser.selectedCount, 2);
      final zip = await _tempPath('picked.zip');
      expect(
        await browser.downloadEntries(browser.selectedEntries, zipPath: zip),
        2,
      );
      final archive = ZipDecoder().decodeBytes(File(zip).readAsBytesSync());
      expect(archive.files.map((f) => f.name).toSet(), {'a.txt', 'b.txt'});

      final choices = await browser.folderChoices(browser.currentFolderId);
      expect(choices.single.name, 'Sub');
      expect(
        await browser.moveEntries([
          named('a.txt'),
          named('b.txt'),
        ], choices.single.id),
        2,
      );
      expect(browser.entries.map((e) => e.name), ['Sub']);
      browser.open(named('Sub'));
      await browser.refresh();
      expect(browser.entries.map((e) => e.name), ['a.txt', 'b.txt']);
      expect(await browser.deleteEntries(browser.entries), 2);
      expect(browser.entries, isEmpty);
    },
  );
}
