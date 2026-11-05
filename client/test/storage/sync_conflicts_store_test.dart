import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/storage/sync_conflicts_store.dart';
import 'package:homebox_client/features/sync/sync_conflict_log.dart';

void main() {
  late LocalDatabase database;
  late SyncConflictLog log;

  setUp(() {
    database = LocalDatabase.openInMemory();
    log = SyncConflictLog(SyncConflictsStore(database.db));
  });

  tearDown(() {
    log.dispose();
    database.dispose();
  });

  test('lists open conflicts newest first and notifies listeners', () {
    var notifications = 0;
    log.addListener(() => notifications++);
    log.record(
      kind: SyncConflictKind.bothModified,
      fileName: 'old.txt',
      detectedAt: DateTime.utc(2026, 1, 1),
    );
    log.record(
      kind: SyncConflictKind.renameRejected,
      fileName: 'new.txt',
      nodeId: 'node-1',
      detectedAt: DateTime.utc(2026, 1, 2),
    );

    expect(notifications, 2);
    expect(log.openCount, 2);
    expect(log.open.map((c) => c.fileName), ['new.txt', 'old.txt']);
    expect(log.open.first.kind, SyncConflictKind.renameRejected);
    expect(log.open.first.nodeId, 'node-1');
  });

  test('tracks a conflict copy until its upload is recorded', () {
    final conflict = log.record(
      kind: SyncConflictKind.bothCreated,
      fileName: 'a.txt',
      conflictCopyPath: 'Docs/a (conflict).txt',
    );
    expect(log.copyAwaitingUpload('Docs/a (conflict).txt')?.id, conflict.id);
    expect(log.copyAwaitingUpload('Docs/a.txt'), isNull);

    log.markCopyUploaded(conflict.id, 'copy-node');
    expect(log.copyAwaitingUpload('Docs/a (conflict).txt'), isNull);
    expect(log.open.single.copyNodeId, 'copy-node');
  });

  test('dismissing hides conflicts and bounds the dismissed history', () {
    final first = log.record(kind: SyncConflictKind.deleteRejected);
    log.record(kind: SyncConflictKind.moveRejected);
    log.dismiss(first.id);
    expect(log.openCount, 1);

    for (var i = 0; i < SyncConflictsStore.maxDismissedRows + 10; i++) {
      log.record(
        kind: SyncConflictKind.bothModified,
        detectedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
      );
    }
    log.dismissAll();
    expect(log.openCount, 0);
    final stored = database.db
        .select('SELECT COUNT(*) AS n FROM sync_conflicts')
        .first['n'];
    expect(stored, SyncConflictsStore.maxDismissedRows);
  });
}
