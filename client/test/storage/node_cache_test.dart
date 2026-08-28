import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/storage/local_database.dart';
import 'package:homebox_client/core/storage/node_cache.dart';

LocalNode _node(String id, {String? parentId, String nodeType = 'FILE', int revision = 1, bool pendingCreate = false, DateTime? deletedAt}) {
  final now = DateTime.utc(2026, 1, 1);
  return LocalNode(
    id: id,
    parentId: parentId,
    nodeType: nodeType,
    metadataCiphertext: Uint8List.fromList([1, 2, 3]),
    metadataKeyVersion: 1,
    currentVersionId: null,
    revision: revision,
    createdAt: now,
    updatedAt: now,
    deletedAt: deletedAt,
    pendingCreate: pendingCreate,
  );
}

void main() {
  test('upsert then getById round-trips every field', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final cache = NodeCache(db.db);

    cache.upsert(_node('n1', parentId: 'root', nodeType: 'DIRECTORY', revision: 3, pendingCreate: true));
    final loaded = cache.getById('n1')!;
    expect(loaded.parentId, 'root');
    expect(loaded.nodeType, 'DIRECTORY');
    expect(loaded.revision, 3);
    expect(loaded.pendingCreate, isTrue);
    expect(loaded.metadataCiphertext, [1, 2, 3]);
  });

  test('upsert overwrites an existing row rather than duplicating it', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final cache = NodeCache(db.db);

    cache.upsert(_node('n1', revision: 1));
    cache.upsert(_node('n1', revision: 2));
    expect(cache.getById('n1')!.revision, 2);
    expect(cache.listChildren(null), hasLength(1));
  });

  test('listChildren separates root from a specific parent, excluding soft-deleted nodes', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final cache = NodeCache(db.db);

    cache.upsert(_node('root-a'));
    cache.upsert(_node('root-b', deletedAt: DateTime.utc(2026, 1, 2)));
    cache.upsert(_node('child-a', parentId: 'root-a'));

    expect(cache.listChildren(null).map((n) => n.id), ['root-a']);
    expect(cache.listChildren('root-a').map((n) => n.id), ['child-a']);
    expect(cache.listChildren('does-not-exist'), isEmpty);
  });

  test('listTrash returns only soft-deleted nodes, newest first', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final cache = NodeCache(db.db);

    cache.upsert(_node('kept'));
    cache.upsert(_node('trashed-1', deletedAt: DateTime.utc(2026, 1, 1)));
    cache.upsert(_node('trashed-2', deletedAt: DateTime.utc(2026, 1, 3)));

    final trash = cache.listTrash();
    expect(trash.map((n) => n.id), ['trashed-2', 'trashed-1']);
  });

  test('remove deletes the row entirely', () {
    final db = LocalDatabase.openInMemory();
    addTearDown(db.dispose);
    final cache = NodeCache(db.db);

    cache.upsert(_node('n1'));
    cache.remove('n1');
    expect(cache.getById('n1'), isNull);
  });
}
