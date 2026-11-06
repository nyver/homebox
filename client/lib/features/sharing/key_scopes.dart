// ignore_for_file: prefer_initializing_formals
import '../../core/storage/node_cache.dart';

/// Decides which key scope new content must be encrypted with (ADR-023):
/// the nearest shared folder at or above its position, or the owner's
/// personal Vault otherwise. Shared folders never nest, so the nearest one
/// is the only one.
///
/// Existing nodes keep their current scope when renamed or given a new
/// version, so a node's metadata and all of its File DEKs always share one
/// scope; [SharedScopeReconciler] moves them together when a node ends up
/// below a shared folder it is not yet encrypted for.
final class KeyScopeResolver {
  KeyScopeResolver({
    required NodeCache nodeCache,
    required bool Function(String folderId) isKeyedFolder,
    required this.userId,
  }) : _nodeCache = nodeCache,
       _isKeyedFolder = isKeyedFolder;

  final NodeCache _nodeCache;
  final bool Function(String folderId) _isKeyedFolder;
  final String userId;

  /// Bounds the ancestor walk; the server refuses deeper trees anyway.
  static const int _maxDepth = 10000;

  /// The scope a new child of [parentId] belongs to.
  String forNewChild(String? parentId) =>
      nearestKeyedFolder(parentId) ?? userId;

  /// The scope [node] should be in at its current position.
  String targetFor(LocalNode node) =>
      node.isDirectory && _isKeyedFolder(node.id)
      ? node.id
      : forNewChild(node.parentId);

  /// [folderId] itself or its closest ancestor with a folder key.
  String? nearestKeyedFolder(String? folderId) {
    var current = folderId;
    for (var depth = 0; current != null && depth < _maxDepth; depth++) {
      if (_isKeyedFolder(current)) return current;
      current = _nodeCache.getById(current)?.parentId;
    }
    return null;
  }
}
