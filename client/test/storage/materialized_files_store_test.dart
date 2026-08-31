import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/storage/materialized_files_store.dart';

void main() {
  test('upsert then getById round-trips every field', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = MaterializedFilesStore(db.db);

    store.upsert(
      const MaterializedFile(
        nodeId: 'n1',
        relativePath: 'Docs/photo.jpg',
        contentVersionId: 'v3',
      ),
    );
    final loaded = store.getById('n1')!;
    expect(loaded.relativePath, 'Docs/photo.jpg');
    expect(loaded.contentVersionId, 'v3');
  });

  test(
    'contentVersionId may be null (node created but no content uploaded yet)',
    () {
      final db = LocalDatabase.openInMemory();
      addTearDown(db.dispose);
      final store = MaterializedFilesStore(db.db);

      store.upsert(
        const MaterializedFile(
          nodeId: 'n1',
          relativePath: 'Docs',
          contentVersionId: null,
        ),
      );
      expect(store.getById('n1')!.contentVersionId, isNull);
    },
  );

  test('upsert overwrites an existing row rather than duplicating it', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = MaterializedFilesStore(db.db);

    store.upsert(
      const MaterializedFile(
        nodeId: 'n1',
        relativePath: 'a.txt',
        contentVersionId: 'v1',
      ),
    );
    store.upsert(
      const MaterializedFile(
        nodeId: 'n1',
        relativePath: 'b.txt',
        contentVersionId: 'v2',
      ),
    );

    expect(store.getById('n1')!.relativePath, 'b.txt');
    expect(store.getById('n1')!.contentVersionId, 'v2');
    expect(store.listAll(), hasLength(1));
  });

  test('listAll returns every tracked file', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = MaterializedFilesStore(db.db);

    store.upsert(
      const MaterializedFile(
        nodeId: 'n1',
        relativePath: 'a.txt',
        contentVersionId: 'v1',
      ),
    );
    store.upsert(
      const MaterializedFile(
        nodeId: 'n2',
        relativePath: 'b.txt',
        contentVersionId: 'v1',
      ),
    );

    expect(store.listAll().map((f) => f.nodeId), containsAll(['n1', 'n2']));
  });

  test('remove deletes the row entirely', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = MaterializedFilesStore(db.db);

    store.upsert(
      const MaterializedFile(
        nodeId: 'n1',
        relativePath: 'a.txt',
        contentVersionId: 'v1',
      ),
    );
    store.remove('n1');

    expect(store.getById('n1'), isNull);
    expect(store.listAll(), isEmpty);
  });

  test('clear forgets all materialized paths without touching disk', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final store = MaterializedFilesStore(db.db);
    store.upsert(
      const MaterializedFile(
        nodeId: 'n1',
        relativePath: 'a.txt',
        contentVersionId: 'v1',
      ),
    );
    store.upsert(
      const MaterializedFile(
        nodeId: 'n2',
        relativePath: 'b.txt',
        contentVersionId: 'v2',
      ),
    );

    store.clear();

    expect(store.listAll(), isEmpty);
  });
}
