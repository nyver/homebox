// ignore_for_file: prefer_initializing_formals
import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/metadata_cipher.dart';
import '../../core/e2ee/scoped_metadata.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/folder_keys_store.dart';
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

  /// [folderId] itself or its closest ancestor with a folder key.
  String? nearestKeyedFolder(String? folderId) {
    var current = folderId;
    for (var depth = 0; current != null && depth < _maxDepth; depth++) {
      if (_isKeyedFolder(current)) return current;
      current = _nodeCache.getById(current)?.parentId;
    }
    return null;
  }

  /// Whether a folder below [folderId] (or [folderId] itself, when
  /// [includeSelf]) is a shared folder. Shared folders never nest, so such
  /// a subtree can neither be shared as a whole nor moved into one.
  bool subtreeHasKeyedFolder(String folderId, {bool includeSelf = true}) {
    final pending = [folderId];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      if ((includeSelf || id != folderId) && _isKeyedFolder(id)) return true;
      for (final child in _nodeCache.listChildren(id)) {
        if (child.isDirectory) pending.add(child.id);
      }
    }
    return false;
  }
}

/// Everything one owner-side operation encrypts and decrypts with: the key
/// ring and the scope rules that pick a key for new content. Dispose it when
/// the operation ends so key bytes are erased.
final class OwnerKeys {
  OwnerKeys(this.ring, this.scopes);

  final OwnerKeyRing ring;
  final KeyScopeResolver scopes;

  String get userId => ring.userId;

  /// Opens the keys of [userId], or returns null without a vault.
  static Future<OwnerKeys?> open({
    required VaultKeyStore vaultKeyStore,
    required NodeCache nodeCache,
    required FolderKeysStore folderKeys,
    required String userId,
  }) async {
    final ring = await openOwnerKeyRing(
      vaultKeyStore: vaultKeyStore,
      userId: userId,
      wrappedFolderKeys: folderKeys.all(),
    );
    if (ring == null) return null;
    return OwnerKeys(
      ring,
      KeyScopeResolver(
        nodeCache: nodeCache,
        isKeyedFolder: folderKeys.isKeyedFolder,
        userId: userId,
      ),
    );
  }

  Future<SensitiveNodeMetadata> decrypt(LocalNode node) => decryptNodeMetadata(
    keys: ring,
    ciphertext: node.metadataCiphertext,
    scopeId: node.scopeOrOwner(userId),
    isDirectory: node.isDirectory,
    nodeId: node.id,
  );

  /// The newest key of the scope a new child of [parentId] belongs to.
  Future<ScopedKey> forNewChild(String? parentId) =>
      ring.current(scopes.forNewChild(parentId));

  /// The newest key of the scope [node] is currently encrypted in. A rename
  /// or new version stays in that scope, so the node's metadata and File
  /// DEKs never diverge.
  Future<ScopedKey> forExisting(LocalNode node) =>
      ring.current(node.scopeOrOwner(userId));

  void dispose() => ring.dispose();
}
