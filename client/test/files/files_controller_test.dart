import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/e2ee/opaque_id.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/files/files_controller.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';

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
  final Map<String, Map<String, dynamic>> _fileVersions = {}; // by nodeId
  final Map<String, Uint8List> _blobs = {}; // by nodeId

  Future<HttpServer> start() => startFixtureServer(_handle);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (method == 'POST' && path == '/api/v1/auth/login') {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
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
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
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
      final children = _nodes.values.where((n) => n['parentId'] == parentId).toList();
      _writeJson(request, 200, children);
    } else if (method == 'POST' && path == '/api/v1/uploads') {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      final uploadId = generateUuidV4();
      _uploadSessions[uploadId] = body;
      _uploadChunks[uploadId] = List.filled(body['chunkCount'] as int, Uint8List(0));
      _writeJson(request, 201, {'id': uploadId, 'chunkCount': body['chunkCount'], 'receivedChunks': <int>[]});
    } else if (method == 'PUT' && path.contains('/chunks/')) {
      final segments = request.uri.pathSegments;
      final uploadId = segments[segments.length - 3];
      final chunkNo = int.parse(segments.last);
      _uploadChunks[uploadId]![chunkNo] = await _collectBytes(request);
      request.response.statusCode = 204;
      await request.response.close();
    } else if (method == 'POST' && path.endsWith('/complete')) {
      final uploadId = request.uri.pathSegments[request.uri.pathSegments.length - 2];
      final session = _uploadSessions[uploadId]!;
      final nodeId = session['targetNodeId'] as String;
      final fileVersionId = session['fileVersionId'] as String;
      final blobBuilder = BytesBuilder(copy: false);
      for (final chunk in _uploadChunks[uploadId]!) {
        blobBuilder.add(chunk);
      }
      _blobs[nodeId] = blobBuilder.takeBytes();
      _fileVersions[nodeId] = {
        'id': fileVersionId,
        'blobId': session['blobId'],
        'e2eeHeader': session['e2eeHeader'],
        'wrappedFileKey': session['wrappedFileKey'],
        'keyScopeId': 'scope',
        'keyVersion': 1,
        'revision': 2,
        'chunkCount': session['chunkCount'],
      };
      _nodes[nodeId]!['currentVersionId'] = fileVersionId;
      _nodes[nodeId]!['revision'] = 2;
      _writeJson(request, 200, {'blobId': session['blobId'], 'fileVersionId': fileVersionId, 'revision': 2});
    } else if (method == 'GET' && path.endsWith('/versions')) {
      final nodeId = request.uri.pathSegments[request.uri.pathSegments.length - 2];
      final version = _fileVersions[nodeId];
      _writeJson(request, 200, version == null ? <dynamic>[] : [version]);
    } else if (method == 'GET' && path.endsWith('/content')) {
      final nodeId = request.uri.pathSegments[request.uri.pathSegments.length - 2];
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

Future<ServerConnectionController> _connectedAndSignedIn(HttpServer httpServer) async {
  final controller = ServerConnectionController(
    deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
    serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
    sessionStore: SessionStore(MemorySessionStorage()),
  );
  await controller.discover('127.0.0.1:${httpServer.port}');
  await controller.confirmTrust();
  await controller.login('admin', 'correct horse battery staple');
  if (controller.status != ServerConnectionStatus.authenticated) {
    throw StateError('test setup failed to authenticate: ${controller.errorMessage}');
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
    final controller = FilesController(
      serverConnection: serverConnection,
      vaultKeyStore: VaultKeyStore(MemoryVaultKeyStorage()),
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
    final recoverySecret = await vaultKeyStore.createVault(userId: _FakeServer.userId);
    recoverySecret.destroy();

    final controller = FilesController(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore);
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

    final tempDir = await Directory.systemTemp.createTemp('homebox_files_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/photo.jpg');
    final originalBytes = Uint8List.fromList(List<int>.generate(10 * 1024 + 7, (i) => i % 256));
    await sourceFile.writeAsBytes(originalBytes);

    expect(await controller.uploadFile(sourceFile.path), isTrue, reason: controller.errorMessage);
    expect(controller.entries, hasLength(1));
    final uploaded = controller.entries.single;
    expect(uploaded.name, 'photo.jpg');
    expect(uploaded.isDirectory, isFalse);
    expect(uploaded.metadata.plaintextSha256, isNotNull);

    final destinationPath = '${tempDir.path}/downloaded.jpg';
    expect(await controller.downloadFile(uploaded, destinationPath), isTrue, reason: controller.errorMessage);
    final downloadedBytes = await File(destinationPath).readAsBytes();
    expect(downloadedBytes, originalBytes);
  });

  test('downloadFile refuses to save content whose plaintext hash does not match the encrypted metadata', () async {
    final fakeServer = _FakeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final vaultKeyStore = VaultKeyStore(MemoryVaultKeyStorage());
    final recoverySecret = await vaultKeyStore.createVault(userId: _FakeServer.userId);
    recoverySecret.destroy();
    final controller = FilesController(serverConnection: serverConnection, vaultKeyStore: vaultKeyStore);
    addTearDown(controller.dispose);

    final tempDir = await Directory.systemTemp.createTemp('homebox_files_test_');
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
