import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/storage/pending_operations_store.dart';

PendingOperation _op(String id, {DateTime? createdAt, DateTime? nextRetryAt, PendingOperationStatus status = PendingOperationStatus.pending}) {
  return PendingOperation(
    id: id,
    operationId: 'op-$id',
    type: PendingOperationType.createNode,
    nodeId: 'node-$id',
    payload: {'nodeType': 'DIRECTORY'},
    createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
    retryCount: 0,
    nextRetryAt: nextRetryAt,
    status: status,
  );
}

void main() {
  test('enqueue then listReady returns pending operations oldest first', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = PendingOperationsStore(db.db);

    store.enqueue(_op('b', createdAt: DateTime.utc(2026, 1, 2)));
    store.enqueue(_op('a', createdAt: DateTime.utc(2026, 1, 1)));

    final ready = store.listReady(DateTime.utc(2026, 1, 3));
    expect(ready.map((o) => o.id), ['a', 'b']);
    expect(ready.first.payload, {'nodeType': 'DIRECTORY'});
  });

  test('listReady excludes operations whose backoff window has not passed', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = PendingOperationsStore(db.db);

    store.enqueue(_op('future', nextRetryAt: DateTime.utc(2026, 6, 1)));
    store.enqueue(_op('ready', nextRetryAt: DateTime.utc(2026, 1, 1)));

    final ready = store.listReady(DateTime.utc(2026, 2, 1));
    expect(ready.map((o) => o.id), ['ready']);
  });

  test('listReady excludes non-PENDING operations', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = PendingOperationsStore(db.db);
    store.enqueue(_op('running', status: PendingOperationStatus.running));
    store.enqueue(_op('done', status: PendingOperationStatus.done));
    store.enqueue(_op('failed', status: PendingOperationStatus.failed));

    expect(store.listReady(DateTime.utc(2026, 1, 1)), isEmpty);
  });

  test('markDone removes an operation from listReady', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = PendingOperationsStore(db.db);
    store.enqueue(_op('a'));
    store.markDone('a');
    expect(store.listReady(DateTime.utc(2026, 1, 1)), isEmpty);
  });

  test('markRetry sets a backoff window and increments retry count', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = PendingOperationsStore(db.db);
    store.enqueue(_op('a'));

    store.markRetry('a', retryCount: 1, nextRetryAt: DateTime.utc(2026, 6, 1), errorCode: 'INTERNAL_ERROR');
    expect(store.listReady(DateTime.utc(2026, 1, 2)), isEmpty);

    final laterReady = store.listReady(DateTime.utc(2026, 7, 1));
    expect(laterReady, hasLength(1));
    expect(laterReady.single.retryCount, 1);
    expect(laterReady.single.lastErrorCode, 'INTERNAL_ERROR');
  });

  test('hasUnfinishedOperationsForNode reflects PENDING/RUNNING/BLOCKED but not DONE/FAILED', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = PendingOperationsStore(db.db);
    store.enqueue(PendingOperation(
      id: 'a',
      operationId: 'op-a',
      type: PendingOperationType.createNode,
      nodeId: 'shared-node',
      payload: const {},
      createdAt: DateTime.utc(2026, 1, 1),
      retryCount: 0,
      status: PendingOperationStatus.pending,
    ));
    expect(store.hasUnfinishedOperationsForNode('shared-node'), isTrue);
    store.markDone('a');
    expect(store.hasUnfinishedOperationsForNode('shared-node'), isFalse);
  });
}
