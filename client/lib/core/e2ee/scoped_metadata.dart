import 'dart:typed_data';

import 'key_ring.dart';
import 'metadata_cipher.dart';
import 'opaque_id.dart';

final MetadataCipher _defaultCipher = MetadataCipher();

/// Decrypts a node's metadata with the key of [scopeId] at the version the
/// envelope names (ADR-023). [scopeId] is the node's recorded key scope:
/// the owner's account ID for the personal Vault, or a shared folder's ID.
/// Every component that reads node metadata goes through this function, so
/// scope handling cannot drift between them.
Future<SensitiveNodeMetadata> decryptNodeMetadata({
  required KeyRing keys,
  required List<int> ciphertext,
  required String scopeId,
  required bool isDirectory,
  required String nodeId,
  MetadataCipher? cipher,
}) async {
  final envelope = EncryptedMetadataEnvelope.decode(ciphertext);
  final key = await keys.key(scopeId, envelope.keyVersion);
  return (cipher ?? _defaultCipher).decrypt(
    envelope: envelope,
    metadataKey: key.key,
    nodeType: isDirectory ? MetadataNodeType.directory : MetadataNodeType.file,
    scopeId: key.scopeIdBytes,
    nodeId: uuidStringToBytes(nodeId),
  );
}

/// Encrypts [metadata] for [nodeId] with [key]; the counterpart of
/// [decryptNodeMetadata].
Future<Uint8List> encryptNodeMetadata({
  required ScopedKey key,
  required SensitiveNodeMetadata metadata,
  required bool isDirectory,
  required String nodeId,
  MetadataCipher? cipher,
}) async {
  final envelope = await (cipher ?? _defaultCipher).encrypt(
    metadata: metadata,
    metadataKey: key.key,
    keyVersion: key.version,
    nodeType: isDirectory ? MetadataNodeType.directory : MetadataNodeType.file,
    scopeId: key.scopeIdBytes,
    nodeId: uuidStringToBytes(nodeId),
  );
  return envelope.encode();
}
