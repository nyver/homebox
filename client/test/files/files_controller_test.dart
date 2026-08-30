import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/e2ee/opaque_id.dart';
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
import '../transport/fixture_server.dart';

/// A minimal, stateful fake HomeBox server covering exactly the login/node/
/// upload/download surface FilesController drives, so this test proves the
/// controller's own orchestration (encrypt -> create node -> upload chunks
/// -> complete -> list -> download -> decrypt -> verify) without needing
/// the real Go binary. Authorization is not enforced (single fake account),
/// matching what the real server's own httpapi integration test already
/// covers separately.
final class _FakeServer {
  static const String userId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

  final Map<String, Map<String, dynamic>> _nodes = {};
  final Map<String, List<Uint8List>> _uploadChunks = {};
  final Map<String, Map<String, dynamic>> _uploadSessions = {};
  final Map<String, List<Map<String, dynamic>>> _fileVersions =
      {}; // by nodeId, newest first
  final Map<String, Uint8List> _blobs = {}; // by nodeId

  Future<HttpServer> start() => startFixtureServer(_handle);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (method == 'POST' && path == '/api/v1/auth/login') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final deviceId = (body['device'] as Map<String, dynamic>)['id'] as String;
      _writeJson(request, 200, {
        'user': {'id': userId, 'username': 'admin', 'role': 'ADMIN'},
        'device': {'id': deviceId, 'platform': 'WINDOWS'},
        'accessToken': 'access-token',
        'accessTokenExpiresAt': '2026-01-01T00:15:00Z',
        'refreshToken': 'refresh-token',
        'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
      });
    } else if (method == 'POST' && path == '/api/v1/nodes') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final id = body['id'] as String;
      final node = {
        'id': id,
        'parentId': body['parentId'],
        'nodeType': body['nodeType'],
        'metadataCiphertext': body['metadataCiphertext'],
        'metadataKeyVersion': body['metadataKeyVersion'],
        'currentVersionId': null,
        'revision': 1,
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
        'deletedAt': null,
      };
      _nodes[id] = node;
      _writeJson(request, 201, node);
    } else if (method == 'GET' && path == '/api/v1/nodes/children') {
      final parentId = request.uri.queryParameters['parentId'];
      final children = _nodes.values
          .where((n) => n['parentId'] == parentId && n['deletedAt'] == null)
          .toList();
      _writeJson(request, 200, children);
    } else if (method == 'GET' && path == '/api/v1/sync/changes') {
      _writeJson(request, 200, {
        'changes': <dynamic>[],
        'nextAfter': 0,
        'hasMore': false,
      });
    } else if (method == 'PATCH' && path.startsWith('/api/v1/nodes/')) {
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      if (node == null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'not found',
            'requestId': 'req',
          },
        });
        return;
      }
      if (node['revision'] != body['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {
            'code': 'REVISION_CONFLICT',
            'message': 'stale revision',
            'requestId': 'req',
          },
        });
        return;
      }
      if (body['metadataCiphertext'] != null) {
        node['metadataCiphertext'] = body['metadataCiphertext'];
        node['metadataKeyVersion'] = body['metadataKeyVersion'];
      }
      if (body['moveParent'] == true) {
        node['parentId'] = body['parentId'];
      }
      node['revision'] = (node['revision'] as int) + 1;
      _writeJson(request, 200, node);
    } else if (method == 'DELETE' && path.startsWith('/api/v1/nodes/')) {
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      if (node == null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'not found',
            'requestId': 'req',
          },
        });
        return;
      }
      if (node['revision'] != body['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {
            'code': 'REVISION_CONFLICT',
            'message': 'stale revision',
            'requestId': 'req',
          },
        });
        return;
      }
      node['deletedAt'] = '2026-01-01T00:00:00Z';
      node['revision'] = (node['revision'] as int) + 1;
      request.response.statusCode = 204;
      await request.response.close();
    } else if (method == 'GET' && path.startsWith('/api/v1/nodes/')) {
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      if (node == null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'not found',
            'requestId': 'req',
          },
        });
      } else {
        _writeJson(request, 200, node);
      }
    } else if (method == 'POST' && path == '/api/v1/uploads') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final uploadId = generateUuidV4();
      _uploadSessions[uploadId] = body;
      _uploadChunks[uploadId] = List.filled(
        body['chunkCount'] as int,
        Uint8List(0),
      );
      _writeJson(request, 201, {
        'id': uploadId,
        'chunkCount': body['chunkCount'],
        'receivedChunks': <int>[],
      });
    } else if (method == 'PUT' && path.contains('/chunks/')) {
      final segments = request.uri.pathSegments;
      final uploadId = segments[segments.length - 3];
      final chunkNo = int.parse(segments.last);
      _uploadChunks[uploadId]![chunkNo] = await _collectBytes(request);
      request.response.statusCode = 204;
      await request.response.close();
    } else if (method == 'POST' && path.endsWith('/complete')) {
      final uploadId =
          request.uri.pathSegments[request.uri.pathSegments.length - 2];
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final session = _uploadSessions[uploadId]!;
      final nodeId = session['targetNodeId'] as String;
      final node = _nodes[nodeId]!;
      if (node['revision'] != body['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {
            'code': 'REVISION_CONFLICT',
            'message': 'stale revision',
            'requestId': 'req',
          },
        });
        return;
      }
      final fileVersionId = session['fileVersionId'] as String;
      final blobBuilder = BytesBuilder(copy: false);
      for (final chunk in _uploadChunks[uploadId]!) {
        blobBuilder.add(chunk);
      }
      _blobs[nodeId] = blobBuilder.takeBytes();
      final newRevision = (node['revision'] as int) + 1;
      _fileVersions.putIfAbsent(nodeId, () => []).insert(0, {
        'id': fileVersionId,
        'blobId': session['blobId'],
        'e2eeHeader': session['e2eeHeader'],
        'wrappedFileKey': session['wrappedFileKey'],
        'keyScopeId': 'scope',
        'keyVersion': 1,
        'revision': newRevision,
        'chunkCount': session['chunkCount'],
      });
      node['currentVersionId'] = fileVersionId;
      node['revision'] = newRevision;
      _writeJson(request, 200, {
        'blobId': session['blobId'],
        'fileVersionId': fileVersionId,
        'revision': newRevision,
      });
    } else if (method == 'GET' && path.endsWith('/versions')) {
      final nodeId =
          request.uri.pathSegments[request.uri.pathSegments.length - 2];
      _writeJson(request, 200, _fileVersions[nodeId] ?? <dynamic>[]);
    } else if (method == 'GET' && path.endsWith('/content')) {
      final nodeId =
          request.uri.pathSegments[request.uri.pathSegments.length - 2];
      final blob = _blobs[nodeId];
      if (blob == null) {
        request.response.statusCode = 404;
        await request.response.close();
      } else {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.binary
          ..add(blob);
        await request.response.close();
      }
    } else {
      request.response.statusCode = 404;
      await request.response.close();
    }
  }

  void _writeJson(HttpRequest request, int status, Object body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    request.response.close();
  }
}

Future<Uint8List> _collectBytes(HttpRequest request) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Waits for a background [SyncEngine.runOnce] (started by e.g.
/// [FilesController.createFolder] via `unawaited`) to actually finish its
/// real HTTP round trips. `pumpEventQueue` only flushes microtasks/timers a
/// fixed number of times, which is not reliably enough for several
/// sequential real localhost socket round trips (push, then its follow-up
/// GET, then the sync pull); polling wall-clock time via `Future.delayed`
/// lets the event loop actually service that I/O.
Future<void> _awaitBackgroundSync(SyncEngine engine) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (engine.status == SyncStatus.syncing) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('SyncEngine did not settle within the test timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<ServerConnectionController> _connectedAndSignedIn(
  HttpServer httpServer,
) async {
  final controller = ServerConnectionController(
    deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
    serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
    sessionStore: SessionStore(MemorySessionStorage()),
  );
  await controller.discover('127.0.0.1:${httpServer.port}');
  await controller.confirmTrust();
  await controller.login('admin', 'correct horse battery staple');
  if (controller.status != ServerConnectionStatus.authenticated) {
    throw StateError(
      'test setup failed to authenticate: ${controller.errorMessage}',
    );
  }
  return controller;
}

void main() {
  test('createFolder fails clearly before a server connection, sign-in, and vault exist', () async {
    final serverConnection = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
      sessionStore: SessionStore(MemorySessionStorage()),
    );
    addTearDown(serverConnection.dispose);
    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: VaultKeyStore(MemoryVaultKeyStorage()),
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    expect(await controller.createFolder('Docs'), isFalse);
    expect(controller.errorMessage, contains('Connect'));
  });

  test('create folder, upload a file into it, list, download, and verify the plaintext round-trips exactly', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);

    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(
      userId: _FakeServer.userId,
    );
    recoverySecret.destroy();

    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    expect(await controller.createFolder('Documents'), isTrue);
    expect(controller.status, FilesStatus.ready);
    expect(controller.entries, hasLength(1));
    expect(controller.entries.single.name, 'Documents');
    expect(controller.entries.single.isDirectory, isTrue);

    controller.openFolder(controller.entries.single);
    await pumpEventQueue();
    expect(controller.breadcrumbNames, ['Documents']);
    expect(controller.entries, isEmpty);

    final tempDir = await Directory.systemTemp.createTemp(
      'homebox_files_test_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/photo.jpg');
    final originalBytes = Uint8List.fromList(
      List<int>.generate(10 * 1024 + 7, (i) => i % 256),
    );
    await sourceFile.writeAsBytes(originalBytes);

    expect(
      await controller.uploadFile(sourceFile.path),
      isTrue,
      reason: controller.errorMessage,
    );
    expect(controller.entries, hasLength(1));
    final uploaded = controller.entries.single;
    expect(uploaded.name, 'photo.jpg');
    expect(uploaded.isDirectory, isFalse);
    expect(uploaded.metadata.plaintextSha256, isNotNull);
    expect(uploaded.metadata.plaintextSize, originalBytes.length);

    final destinationPath = '${tempDir.path}/downloaded.jpg';
    expect(
      await controller.downloadFile(uploaded, destinationPath),
      isTrue,
      reason: controller.errorMessage,
    );
    final downloadedBytes = await File(destinationPath).readAsBytes();
    expect(downloadedBytes, originalBytes);
  });

  test('busy transfers report their direction so the Files page can label upload vs. download progress', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(
      userId: _FakeServer.userId,
    );
    recoverySecret.destroy();
    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    final tempDir = await Directory.systemTemp.createTemp(
      'homebox_files_test_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/photo.jpg');
    await sourceFile.writeAsBytes(
      Uint8List.fromList(List<int>.generate(10 * 1024 + 7, (i) => i % 256)),
    );

    final observedDirections = <FileTransferDirection?>[];
    controller.addListener(() {
      if (controller.busy) observedDirections.add(controller.transferDirection);
    });

    expect(
      await controller.uploadFile(sourceFile.path),
      isTrue,
      reason: controller.errorMessage,
    );
    expect(observedDirections, isNotEmpty);
    expect(observedDirections, everyElement(FileTransferDirection.upload));
    expect(controller.transferDirection, isNull, reason: 'reset once idle');

    observedDirections.clear();
    final destinationPath = '${tempDir.path}/downloaded.jpg';
    expect(
      await controller.downloadFile(controller.entries.single, destinationPath),
      isTrue,
      reason: controller.errorMessage,
    );
    expect(observedDirections, isNotEmpty);
    expect(observedDirections, everyElement(FileTransferDirection.download));
    expect(controller.transferDirection, isNull, reason: 'reset once idle');
  });

  test('downloadFile and replaceFileContent refuse to start while another transfer is already busy', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(
      userId: _FakeServer.userId,
    );
    recoverySecret.destroy();
    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    final tempDir = await Directory.systemTemp.createTemp(
      'homebox_files_test_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final existing = File('${tempDir.path}/existing.bin');
    await existing.writeAsBytes(
      Uint8List.fromList(List<int>.generate(5 * 1024, (i) => i % 256)),
    );
    expect(
      await controller.uploadFile(existing.path),
      isTrue,
      reason: controller.errorMessage,
    );
    final existingEntry = controller.entries.single;

    final second = File('${tempDir.path}/second.bin');
    await second.writeAsBytes(
      Uint8List.fromList(List<int>.generate(64 * 1024, (i) => i % 256)),
    );
    // Kicked off but not awaited, so it's still in flight (busy == true)
    // while the assertions below run against it concurrently.
    final inFlight = controller.uploadFiles([second.path]);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!controller.busy) {
      if (DateTime.now().isAfter(deadline)) {
        fail('uploadFiles never reported busy within the test timeout.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(
      await controller.replaceFileContent(existingEntry, second.path),
      isFalse,
    );
    expect(controller.errorMessage, contains('already in progress'));
    expect(
      await controller.downloadFile(
        existingEntry,
        '${tempDir.path}/downloaded.bin',
      ),
      isFalse,
    );
    expect(controller.errorMessage, contains('already in progress'));

    final result = await inFlight;
    expect(
      result.succeeded,
      1,
      reason: 'the original in-flight upload must complete undisturbed',
    );
  });

  test('uploadFiles keeps a dropped batch in its opening folder and continues after one bad path', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(
      userId: _FakeServer.userId,
    );
    recoverySecret.destroy();
    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    expect(await controller.createFolder('Dropped files'), isTrue);
    controller.openFolder(controller.entries.single);
    await pumpEventQueue();

    final tempDir = await Directory.systemTemp.createTemp('homebox_drop_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final first = File('${tempDir.path}/first.txt');
    final second = File('${tempDir.path}/second.txt');
    await first.writeAsString('first');
    await second.writeAsString('second');

    final result = await controller.uploadFiles([
      first.path,
      '${tempDir.path}/no-longer-here.txt',
      second.path,
    ]);

    expect(result.succeeded, 2);
    expect(result.failed, 1);
    expect(controller.entries.map((entry) => entry.name), [
      'first.txt',
      'second.txt',
    ]);
    for (final entry in controller.entries) {
      expect(fakeServer._nodes[entry.node.id]!['parentId'], isNotNull);
    }
  });

  test('replaceFileContent adds a new version without creating a new node, and download fetches the latest', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(
      userId: _FakeServer.userId,
    );
    recoverySecret.destroy();
    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    final tempDir = await Directory.systemTemp.createTemp(
      'homebox_files_test_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/note.txt');
    await sourceFile.writeAsBytes(utf8.encode('version one'));
    expect(
      await controller.uploadFile(sourceFile.path),
      isTrue,
      reason: controller.errorMessage,
    );
    final firstVersion = controller.entries.single;
    final revisionAfterFirstUpload = firstVersion.node.revision;

    await sourceFile.writeAsBytes(
      utf8.encode('version two, replacing the first'),
    );
    expect(
      await controller.replaceFileContent(firstVersion, sourceFile.path),
      isTrue,
      reason: controller.errorMessage,
    );
    expect(
      controller.entries,
      hasLength(1),
      reason: 'no new node should have been created',
    );
    final secondVersion = controller.entries.single;
    expect(secondVersion.node.id, firstVersion.node.id);
    expect(secondVersion.node.revision, greaterThan(revisionAfterFirstUpload));
    expect(
      secondVersion.metadata.plaintextSize,
      'version two, replacing the first'.length,
    );
    expect(
      fakeServer._fileVersions[firstVersion.node.id],
      hasLength(2),
      reason: 'the earlier version must remain retrievable',
    );

    final destinationPath = '${tempDir.path}/downloaded.txt';
    expect(
      await controller.downloadFile(secondVersion, destinationPath),
      isTrue,
      reason: controller.errorMessage,
    );
    expect(
      await File(destinationPath).readAsString(),
      'version two, replacing the first',
    );
  });

  test('renameNode and deleteNode apply locally right away and reach the server through the outbox', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(
      userId: _FakeServer.userId,
    );
    recoverySecret.destroy();
    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    expect(await controller.createFolder('Docs'), isTrue);
    await _awaitBackgroundSync(
      syncEngine,
    ); // let the background push (fired by createFolder) reach the fake server.
    await controller.refresh(); // pick up the confirmed revision, not the pre-push optimistic one.
    final folder = controller.entries.single;
    expect(
      fakeServer._nodes[folder.node.id],
      isNotNull,
      reason: 'the create should have reached the fake server',
    );
    expect(
      folder.node.revision,
      1,
      reason:
          'the local cache should reflect the server-confirmed revision by now',
    );

    expect(await controller.renameNode(folder, 'Renamed'), isTrue);
    expect(
      controller.entries.single.name,
      'Renamed',
      reason: 'the local cache reflects the rename immediately, offline or not',
    );
    await _awaitBackgroundSync(syncEngine);
    expect(
      fakeServer._nodes[folder.node.id]!['revision'],
      2,
      reason: 'the rename should have reached the fake server',
    );

    expect(await controller.deleteNode(controller.entries.single), isTrue);
    expect(
      controller.entries,
      isEmpty,
      reason:
          'a soft-deleted node disappears from its parent listing immediately',
    );
    await _awaitBackgroundSync(syncEngine);
    expect(
      fakeServer._nodes[folder.node.id]!['deletedAt'],
      isNotNull,
      reason: 'the delete should have reached the fake server',
    );
  });

  test('downloadFile refuses to save content whose plaintext hash does not match the encrypted metadata', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(
      userId: _FakeServer.userId,
    );
    recoverySecret.destroy();
    final syncEngine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(syncEngine.dispose);
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: vaultKeyStore,
      syncEngine: syncEngine,
    );
    addTearDown(controller.dispose);

    final tempDir = await Directory.systemTemp.createTemp(
      'homebox_files_test_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/note.txt');
    await sourceFile.writeAsBytes(utf8.encode('original content'));
    await controller.uploadFile(sourceFile.path);
    final uploaded = controller.entries.single;

    // Corrupt the stored ciphertext blob directly, simulating a server-side
    // corruption or tampering event the AEAD tag alone might not catch if
    // it happened to hit only unauthenticated padding — the plaintext hash
    // check is the client's last line of defense either way.
    fakeServer._blobs[uploaded.node.id]![0] ^= 0xff;

    final destinationPath = '${tempDir.path}/should-not-exist.txt';
    final result = await controller.downloadFile(uploaded, destinationPath);
    expect(result, isFalse);
    expect(await File(destinationPath).exists(), isFalse);
  });
}
