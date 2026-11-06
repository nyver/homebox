// Named parameters keep call sites readable (`vaultKey:`), as elsewhere.
// ignore_for_file: prefer_initializing_formals
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_envelope.dart';
import 'opaque_id.dart';
import 'vault_key_store.dart';

/// The key version every shared folder starts with.
const int homeBoxFirstFolderKeyVersion = 1;

/// One key that encrypts node metadata and wraps File DEKs inside a key
/// scope (ADR-023). [scopeId] is an account ID for that account's personal
/// Vault Key, or a shared folder's ID for that folder's Folder Key.
final class ScopedKey {
  const ScopedKey({
    required this.scopeId,
    required this.version,
    required this.key,
  });

  final String scopeId;
  final int version;
  final SecretKey key;

  /// The 16-byte form AEAD contexts bind to.
  Uint8List get scopeIdBytes => uuidStringToBytes(scopeId);
}

/// Thrown when this device does not hold the key a node was encrypted with,
/// for example a folder key that has not been delivered to it yet.
final class MissingScopeKeyException implements Exception {
  const MissingScopeKeyException(this.scopeId, this.version);

  final String scopeId;
  final int version;

  @override
  String toString() =>
      'This device does not hold the key for this shared content yet.';
}

/// Every key one device may use during an operation. A key ring owns the
/// unwrapped keys it hands out: callers must not destroy them, and must call
/// [dispose] when the operation ends so key bytes are erased.
abstract interface class KeyRing {
  /// The key of [scopeId] at exactly [version].
  Future<ScopedKey> key(String scopeId, int version);

  /// The newest key of [scopeId], which new content must use.
  Future<ScopedKey> current(String scopeId);

  void dispose();
}

/// The owner's key ring: its personal Vault Key plus every version of every
/// shared-folder key it created, which stay wrapped by the Vault Key until
/// one is actually needed.
final class OwnerKeyRing implements KeyRing {
  OwnerKeyRing({
    required this.userId,
    required SecretKey vaultKey,
    required int vaultKeyVersion,
    required Map<String, Map<int, Uint8List>> wrappedFolderKeys,
    KeyEnvelopeCipher? cipher,
  }) : _vaultKey = vaultKey,
       _vaultKeyVersion = vaultKeyVersion,
       _wrapped = wrappedFolderKeys,
       _cipher = cipher ?? KeyEnvelopeCipher();

  final String userId;
  final SecretKey _vaultKey;
  final int _vaultKeyVersion;
  final Map<String, Map<int, Uint8List>> _wrapped;
  final KeyEnvelopeCipher _cipher;
  final Map<String, ScopedKey> _opened = {};
  bool _disposed = false;

  /// The personal Vault Key, for callers that wrap material other than
  /// node metadata and File DEKs (such as a new folder key).
  ScopedKey get vaultKey =>
      ScopedKey(scopeId: userId, version: _vaultKeyVersion, key: _vaultKey);

  /// Shared folders this account has created a key for.
  Iterable<String> get keyedFolderIds => _wrapped.keys;

  bool isKeyedFolder(String folderId) => _wrapped.containsKey(folderId);

  @override
  Future<ScopedKey> key(String scopeId, int version) async {
    _checkNotDisposed();
    if (scopeId == userId) {
      if (version != _vaultKeyVersion) {
        throw MissingScopeKeyException(scopeId, version);
      }
      return vaultKey;
    }
    final cacheKey = '$scopeId/$version';
    final cached = _opened[cacheKey];
    if (cached != null) return cached;
    final envelope = _wrapped[scopeId]?[version];
    if (envelope == null) throw MissingScopeKeyException(scopeId, version);
    final folderKey = await unwrapFolderKeyForOwner(
      cipher: _cipher,
      vaultKey: _vaultKey,
      folderId: scopeId,
      ownerUserId: userId,
      envelope: envelope,
      expectedVersion: version,
    );
    final scoped = ScopedKey(
      scopeId: scopeId,
      version: version,
      key: folderKey,
    );
    _opened[cacheKey] = scoped;
    return scoped;
  }

  @override
  Future<ScopedKey> current(String scopeId) {
    if (scopeId == userId) return key(scopeId, _vaultKeyVersion);
    final versions = _wrapped[scopeId];
    if (versions == null || versions.isEmpty) {
      throw MissingScopeKeyException(scopeId, 0);
    }
    return key(scopeId, versions.keys.reduce((a, b) => a > b ? a : b));
  }

  /// The newest version of [folderId]'s key, or 0 when it has none.
  int latestVersion(String folderId) {
    final versions = _wrapped[folderId];
    if (versions == null || versions.isEmpty) return 0;
    return versions.keys.reduce((a, b) => a > b ? a : b);
  }

  /// Makes a freshly created folder key usable within this ring.
  void addWrapped(String folderId, int version, Uint8List envelope) {
    _wrapped.putIfAbsent(folderId, () => {})[version] = envelope;
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('Key ring has been disposed.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final scoped in _opened.values) {
      scoped.key.destroy();
    }
    _opened.clear();
    _vaultKey.destroy();
  }
}

/// A recipient's key ring for shared folders: the folder keys this device
/// opened from envelopes addressed to it.
final class SharedKeyRing implements KeyRing {
  SharedKeyRing(Map<String, Map<int, SecretKey>> keys) : _keys = keys;

  final Map<String, Map<int, SecretKey>> _keys;
  bool _disposed = false;

  bool holds(String scopeId) => _keys[scopeId]?.isNotEmpty ?? false;

  @override
  Future<ScopedKey> key(String scopeId, int version) async {
    if (_disposed) throw StateError('Key ring has been disposed.');
    final key = _keys[scopeId]?[version];
    if (key == null) throw MissingScopeKeyException(scopeId, version);
    return ScopedKey(scopeId: scopeId, version: version, key: key);
  }

  @override
  Future<ScopedKey> current(String scopeId) {
    final versions = _keys[scopeId];
    if (versions == null || versions.isEmpty) {
      throw MissingScopeKeyException(scopeId, 0);
    }
    return key(scopeId, versions.keys.reduce((a, b) => a > b ? a : b));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final versions in _keys.values) {
      for (final key in versions.values) {
        key.destroy();
      }
    }
    _keys.clear();
  }
}

/// Generates a random 256-bit Folder Key.
SecretKey newFolderKey() => SecretKeyData.random(
  length: 32,
  debugLabel: 'HomeBox Family Vault folder key',
);

/// Wraps a folder key with its owner's Vault Key. The AEAD context binds
/// the folder, the owner, and the version, so the server cannot present it
/// as another folder's key.
Future<Uint8List> wrapFolderKeyForOwner({
  KeyEnvelopeCipher? cipher,
  required SecretKey vaultKey,
  required SecretKey folderKey,
  required String folderId,
  required String ownerUserId,
  required int version,
}) async {
  final envelope = await (cipher ?? KeyEnvelopeCipher()).wrapKey(
    wrappingKey: vaultKey,
    keyToWrap: folderKey,
    purpose: KeyEnvelopePurpose.folderKey,
    keyVersion: version,
    scopeId: uuidStringToBytes(folderId),
    subjectId: uuidStringToBytes(ownerUserId),
  );
  return envelope.encode();
}

Future<SecretKey> unwrapFolderKeyForOwner({
  KeyEnvelopeCipher? cipher,
  required SecretKey vaultKey,
  required String folderId,
  required String ownerUserId,
  required Uint8List envelope,
  required int expectedVersion,
}) async {
  final decoded = KeyEnvelope.decode(envelope);
  if (decoded.purpose != KeyEnvelopePurpose.folderKey ||
      decoded.keyVersion != expectedVersion) {
    throw const FormatException('Folder key envelope has the wrong context.');
  }
  return (cipher ?? KeyEnvelopeCipher()).unwrapKey(
    wrappingKey: vaultKey,
    envelope: decoded,
    scopeId: uuidStringToBytes(folderId),
    subjectId: uuidStringToBytes(ownerUserId),
  );
}

/// Opens [userId]'s owner key ring from its stored Vault Key and the given
/// wrapped folder keys, or returns null when this device has no vault yet.
Future<OwnerKeyRing?> openOwnerKeyRing({
  required VaultKeyStore vaultKeyStore,
  required String userId,
  required Map<String, Map<int, Uint8List>> wrappedFolderKeys,
}) async {
  final vaultKey = await vaultKeyStore.loadVaultKey();
  if (vaultKey == null) return null;
  return OwnerKeyRing(
    userId: userId,
    vaultKey: vaultKey,
    vaultKeyVersion: homeBoxPersonalVaultKeyVersion,
    wrappedFolderKeys: wrappedFolderKeys,
  );
}
