import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/storage/pending_operations_store.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/sync/sync_engine.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import 'fake_node_server.dart';

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

PendingOperation _createOp(
  String nodeId, {
  String? parentId,
  DateTime? createdAt,
}) => PendingOperation(
  id: 'pending-$nodeId',
  operationId: 'op-create-$nodeId',
  type: PendingOperationType.createNode,
  nodeId: nodeId,
  payload: {
    'parentId': parentId,
    'nodeType': 'DIRECTORY',
    'metadataCiphertext': base64Encode(utf8.encode('m')),
    'metadataKeyVersion': 1,
  },
  createdAt: createdAt ?? DateTime.now(),
  retryCount: 0,
  status: PendingOperationStatus.pending,
);

void main() {
  test(
    'pushing a pending CREATE succeeds and the node lands in the local cache',
    () async {
      final fakeServer = FakeNodeServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));
      final serverConnection = await _connectedAndSignedIn(httpServer);
      addTearDown(serverConnection.dispose);

      final engine = SyncEngine(
        serverConnection: serverConnection,
        localDatabase: LocalDatabase.openInMemory(),
      );
      addTearDown(engine.dispose);
      engine.pendingOperations.enqueue(_createOp('node-1'));

      await engine.runOnce();

      expect(engine.status, SyncStatus.idle);
      expect(engine.nodeCache.getById('node-1'), isNotNull);
      expect(
        engine.pendingOperations.listReady(
          DateTime.now().add(const Duration(days: 1)),
        ),
        isEmpty,
      );
    },
  );

  test('an UPDATE queued right after a CREATE waits for the CREATE to finish instead of running out of order', () async {
    final fakeServer = FakeNodeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);

    // Force every mutation to fail so the CREATE never finishes.
    fakeServer.failMutationsWithStatus = 500;
    fakeServer.failMutationsWithCode = 'INTERNAL_ERROR';

    final engine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(engine.dispose);
    final createdAt = DateTime.now();
    engine.pendingOperations.enqueue(_createOp('node-1', createdAt: createdAt));
    engine.pendingOperations.enqueue(
      PendingOperation(
        id: 'pending-update',
        operationId: 'op-update',
        type: PendingOperationType.updateNode,
        nodeId: 'node-1',
        payload: {
          'metadataCiphertext': base64Encode(utf8.encode('renamed')),
          'metadataKeyVersion': 1,
        },
        baseRevision: 1,
        createdAt: createdAt.add(const Duration(milliseconds: 1)),
        retryCount: 0,
        status: PendingOperationStatus.pending,
      ),
    );

    await engine.runOnce();

    // The CREATE was attempted (and failed, now backed off); the UPDATE
    // must still be untouched — never attempted at all — because it was
    // skipped by the ordering guard, not because it also failed.
    final remainingReady = engine.pendingOperations.listReady(
      DateTime.now().add(const Duration(minutes: 10)),
    );
    expect(
      remainingReady.map((o) => o.id),
      containsAll(['pending-node-1', 'pending-update']),
    );
    final updateRow = remainingReady.firstWhere(
      (o) => o.id == 'pending-update',
    );
    expect(
      updateRow.retryCount,
      0,
      reason: 'the update should never have been attempted',
    );
    expect(
      engine.nodeCache.getById('node-1'),
      isNull,
      reason: 'the create never succeeded',
    );
  });

  test(
    'pulling changes discovers a node created by a different device',
    () async {
      final fakeServer = FakeNodeServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));
      final serverConnection = await _connectedAndSignedIn(httpServer);
      addTearDown(serverConnection.dispose);

      fakeServer.remoteCreate(id: 'remote-node');

      final engine = SyncEngine(
        serverConnection: serverConnection,
        localDatabase: LocalDatabase.openInMemory(),
      );
      addTearDown(engine.dispose);

      expect(engine.nodeCache.getById('remote-node'), isNull);
      await engine.runOnce();
      expect(engine.nodeCache.getById('remote-node'), isNotNull);

      // A second run with nothing new must not error or re-fetch needlessly
      // (there is nothing after the advanced cursor to pull).
      await engine.runOnce();
      expect(engine.status, SyncStatus.idle);
    },
  );

  test('pausing prevents new sync passes until resume', () async {
    final fakeServer = FakeNodeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    final engine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(engine.dispose);

    engine.pause();
    fakeServer.remoteCreate(id: 'while-paused');
    await engine.runOnce();
    expect(engine.status, SyncStatus.paused);
    expect(engine.nodeCache.getById('while-paused'), isNull);

    engine.resume();
    await engine.runOnce();
    expect(engine.status, SyncStatus.idle);
    expect(engine.nodeCache.getById('while-paused'), isNotNull);
  });

  test('a permanent failure (VALIDATION_ERROR) marks the operation FAILED without retrying', () async {
    final fakeServer = FakeNodeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    fakeServer.failMutationsWithStatus = 400;
    fakeServer.failMutationsWithCode = 'VALIDATION_ERROR';

    final engine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(engine.dispose);
    engine.pendingOperations.enqueue(_createOp('node-1'));

    await engine.runOnce();

    expect(
      engine.pendingOperations.listReady(
        DateTime.now().add(const Duration(days: 1)),
      ),
      isEmpty,
    );
    final op = engine.pendingOperations.getById('pending-node-1')!;
    expect(op.status, PendingOperationStatus.failed);
    expect(op.lastErrorCode, 'VALIDATION_ERROR');
  });

  test('a transient failure (server error) schedules a backoff retry instead of failing permanently', () async {
    final fakeServer = FakeNodeServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final serverConnection = await _connectedAndSignedIn(httpServer);
    addTearDown(serverConnection.dispose);
    fakeServer.failMutationsWithStatus = 500;
    fakeServer.failMutationsWithCode = 'INTERNAL_ERROR';

    final engine = SyncEngine(
      serverConnection: serverConnection,
      localDatabase: LocalDatabase.openInMemory(),
    );
    addTearDown(engine.dispose);
    engine.pendingOperations.enqueue(_createOp('node-1'));

    await engine.runOnce();

    expect(
      engine.pendingOperations.listReady(DateTime.now()),
      isEmpty,
      reason: 'not ready yet, backoff window pending',
    );
    final laterReady = engine.pendingOperations.listReady(
      DateTime.now().add(const Duration(minutes: 10)),
    );
    expect(laterReady, hasLength(1));
    expect(laterReady.single.retryCount, 1);
    expect(laterReady.single.lastErrorCode, 'INTERNAL_ERROR');
  });
}
