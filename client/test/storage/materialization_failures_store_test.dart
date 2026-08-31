import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/storage/materialization_failures_store.dart';

void main() {
  test('an integrity failure survives reopening the local database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'homebox_materialization_failures_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/client.sqlite3';

    final firstDatabase = LocalDatabase.openAtPath(path);
    MaterializationFailuresStore(
      firstDatabase.db,
    ).record(nodeId: 'node-1', contentVersionId: 'version-1', nodeRevision: 7);
    firstDatabase.dispose();

    final reopenedDatabase = LocalDatabase.openAtPath(path);
    addTearDown(reopenedDatabase.dispose);
    final reopenedStore = MaterializationFailuresStore(reopenedDatabase.db);
    expect(
      reopenedStore.contains(
        nodeId: 'node-1',
        contentVersionId: 'version-1',
        nodeRevision: 7,
      ),
      isTrue,
    );
    expect(
      reopenedStore.contains(
        nodeId: 'node-1',
        contentVersionId: 'version-2',
        nodeRevision: 7,
      ),
      isFalse,
    );
    expect(
      reopenedStore.contains(
        nodeId: 'node-1',
        contentVersionId: 'version-1',
        nodeRevision: 8,
      ),
      isFalse,
    );
    expect(reopenedStore.listNodeIds(), ['node-1']);
    reopenedStore.remove('node-1');
    expect(reopenedStore.listNodeIds(), isEmpty);
  });
}
