import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/metadata_cipher.dart';

void main() {
  final cipher = MetadataCipher();
  final key = SecretKeyData(List<int>.generate(32, (index) => 0x40 + index));
  final scopeId = Uint8List.fromList(List<int>.generate(16, (index) => index));
  final nodeId = Uint8List.fromList(
    List<int>.generate(16, (index) => 0x20 + index),
  );
  final metadata = SensitiveNodeMetadata(
    fileName: 'Family Photo.jpg',
    mimeType: 'image/jpeg',
    plaintextSha256: List.filled(64, 'a').join(),
    labels: const ['favorite'],
  );

  test('sensitive metadata round-trips without plaintext leakage', () async {
    final encrypted = await cipher.encrypt(
      metadata: metadata,
      metadataKey: key,
      keyVersion: 2,
      nodeType: MetadataNodeType.file,
      scopeId: scopeId,
      nodeId: nodeId,
    );
    final encoded = encrypted.encode();
    expect(_contains(encoded, utf8.encode(metadata.fileName)), isFalse);
    final decoded = EncryptedMetadataEnvelope.decode(encoded);
    final decrypted = await cipher.decrypt(
      envelope: decoded,
      metadataKey: key,
      nodeType: MetadataNodeType.file,
      scopeId: scopeId,
      nodeId: nodeId,
    );
    expect(decrypted.fileName, metadata.fileName);
    expect(decrypted.mimeType, metadata.mimeType);
    expect(decrypted.plaintextSha256, metadata.plaintextSha256);
    expect(decrypted.labels, metadata.labels);
  });

  test('metadata cannot be moved to another node', () async {
    final encrypted = await cipher.encrypt(
      metadata: metadata,
      metadataKey: key,
      keyVersion: 1,
      nodeType: MetadataNodeType.file,
      scopeId: scopeId,
      nodeId: nodeId,
    );
    final otherNode = Uint8List.fromList(nodeId)..[0] ^= 1;
    await expectLater(
      cipher.decrypt(
        envelope: encrypted,
        metadataKey: key,
        nodeType: MetadataNodeType.file,
        scopeId: scopeId,
        nodeId: otherNode,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('tampered encrypted metadata is rejected', () async {
    final encrypted = await cipher.encrypt(
      metadata: metadata,
      metadataKey: key,
      keyVersion: 1,
      nodeType: MetadataNodeType.file,
      scopeId: scopeId,
      nodeId: nodeId,
    );
    final encoded = encrypted.encode()..[45] ^= 1;
    await expectLater(
      cipher.decrypt(
        envelope: EncryptedMetadataEnvelope.decode(encoded),
        metadataKey: key,
        nodeType: MetadataNodeType.file,
        scopeId: scopeId,
        nodeId: nodeId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var index = 0; index <= haystack.length - needle.length; index++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[index + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
