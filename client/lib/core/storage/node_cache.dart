import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../transport/homebox_api_client.dart' as transport;

/// The local, offline-available mirror of one server node row. Metadata
/// stays ciphertext here too — this cache exists so the Files page can
/// render instantly and work briefly offline, not to weaken the E2EE
/// boundary; decryption still only ever happens where it already did
/// (FilesController), never in this storage layer.
final class LocalNode {
  const LocalNode({
    required this.id,
    required this.parentId,
    required this.nodeType,
    required this.metadataCiphertext,
    required this.metadataKeyVersion,
    required this.currentVersionId,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.pendingCreate,
  });

  final String id;
  final String? parentId;
  final String nodeType; // FILE | DIRECTORY
  final Uint8List metadataCiphertext;
  final int metadataKeyVersion;
  final String? currentVersionId;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  /// True for a node created locally by [PendingOperationType.createNode]
  /// that has not yet been confirmed by the server. A mutation targeting
  /// this node must wait for that create to land first (see SyncEngine).
  final bool pendingCreate;

  bool get isDeleted => deletedAt != null;
  bool get isDirectory => nodeType == 'DIRECTORY';
}

/// Converts a server-confirmed node into its local-cache representation.
/// Shared by every call site that upserts a fetched/created/updated node
/// into [NodeCache] (`SyncEngine`, `FilesController`, and the local
/// sync-folder uploader), so they can never drift into copying different
/// subsets of fields.
LocalNode localNodeFromServerNode(transport.NodeInfo node, {bool pendingCreate = false}) => LocalNode(
      id: node.id,
      parentId: node.parentId,
      nodeType: node.nodeType,
      metadataCiphertext: node.metadataCiphertext,
      metadataKeyVersion: node.metadataKeyVersion,
      currentVersionId: node.currentVersionId,
      revision: node.revision,
      createdAt: node.createdAt,
      updatedAt: node.updatedAt,
      deletedAt: node.deletedAt,
      pendingCreate: pendingCreate,
    );

/// CRUD for the local `nodes` cache table (spec §13). Every method is
/// synchronous: `package:sqlite3` is a synchronous FFI binding, and these
/// calls are all single fast local-disk operations, matching how the rest
/// of this codebase already treats local secure-storage/database access.
final class NodeCache {
  NodeCache(this._db);

  final Database _db;

  void upsert(LocalNode node) {
    _db.execute(
      '''
      INSERT INTO nodes (id, parent_id, node_type, metadata_ciphertext, metadata_key_version, current_version_id, revision, created_at, updated_at, deleted_at, pending_create)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        parent_id = excluded.parent_id,
        node_type = excluded.node_type,
        metadata_ciphertext = excluded.metadata_ciphertext,
        metadata_key_version = excluded.metadata_key_version,
        current_version_id = excluded.current_version_id,
        revision = excluded.revision,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at,
        pending_create = excluded.pending_create
      ''',
      [
        node.id,
        node.parentId,
        node.nodeType,
        node.metadataCiphertext,
        node.metadataKeyVersion,
        node.currentVersionId,
        node.revision,
        node.createdAt.toUtc().toIso8601String(),
        node.updatedAt.toUtc().toIso8601String(),
        node.deletedAt?.toUtc().toIso8601String(),
        node.pendingCreate ? 1 : 0,
      ],
    );
  }

  LocalNode? getById(String id) {
    final rows = _db.select('SELECT * FROM nodes WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  List<LocalNode> listChildren(String? parentId) {
    final rows = parentId == null
        ? _db.select('SELECT * FROM nodes WHERE parent_id IS NULL AND deleted_at IS NULL ORDER BY created_at')
        : _db.select('SELECT * FROM nodes WHERE parent_id = ? AND deleted_at IS NULL ORDER BY created_at', [parentId]);
    return rows.map(_fromRow).toList(growable: false);
  }

  List<LocalNode> listTrash() {
    final rows = _db.select('SELECT * FROM nodes WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC');
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Removes a node the server no longer recognizes at all (as opposed to
  /// soft-deleted, which is represented by `deleted_at` and kept).
  void remove(String id) {
    _db.execute('DELETE FROM nodes WHERE id = ?', [id]);
  }

  LocalNode _fromRow(Row row) => LocalNode(
        id: row['id'] as String,
        parentId: row['parent_id'] as String?,
        nodeType: row['node_type'] as String,
        metadataCiphertext: row['metadata_ciphertext'] as Uint8List,
        metadataKeyVersion: row['metadata_key_version'] as int,
        currentVersionId: row['current_version_id'] as String?,
        revision: row['revision'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        deletedAt: row['deleted_at'] != null ? DateTime.parse(row['deleted_at'] as String) : null,
        pendingCreate: (row['pending_create'] as int) != 0,
      );
}
