import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/file_cipher.dart';

void main() {
  final cipher = E2eeFileCipher();
  final key = SecretKeyData(
    Uint8List.fromList(List<int>.generate(32, (i) => i)),
  );
  final header = E2eeFileHeader(
    protocolVersion: homeBoxE2eeProtocolVersion,
    noncePrefix: Uint8List.fromList(List<int>.generate(16, (i) => 0xa0 + i)),
  );
  final versionId = Uint8List.fromList(List<int>.generate(16, (i) => 0x10 + i));

  test('header has a stable versioned binary format', () {
    expect(
      _hex(header.encode()),
      '484258460001a0a1a2a3a4a5a6a7a8a9aaabacadaeaf',
    );
    final decoded = E2eeFileHeader.decode(header.encode());
    expect(decoded.protocolVersion, homeBoxE2eeProtocolVersion);
    expect(decoded.noncePrefix, header.noncePrefix);
  });

  test('header protects its nonce prefix from mutation', () {
    final source = Uint8List.fromList(List<int>.filled(16, 7));
    final immutableHeader = E2eeFileHeader(
      protocolVersion: homeBoxE2eeProtocolVersion,
      noncePrefix: source,
    );
    source[0] = 8;
    final exposedCopy = immutableHeader.noncePrefix;
    exposedCopy[1] = 9;
    expect(immutableHeader.noncePrefix, List<int>.filled(16, 7));
  });

  test(
    'chunk encryption round-trips and is deterministic for test vector',
    () async {
      final plaintext = utf8.encode('HomeBox E2EE interoperability vector v1');
      final encrypted = await cipher.encryptChunk(
        plaintext: plaintext,
        fileKey: key,
        header: header,
        fileVersionId: versionId,
        chunkNumber: 2,
        totalChunks: 5,
      );
      expect(
        _hex(encrypted),
        '85d57e654fa66896c7797f93e8c9a2596f7e4558f686f51b56c7698e16d35b11733a12bf04f0200a9a7bad9f3a85f74ef0329ab8b76b47',
      );
      final decrypted = await cipher.decryptChunk(
        ciphertextFrame: encrypted,
        fileKey: key,
        header: header,
        fileVersionId: versionId,
        chunkNumber: 2,
        totalChunks: 5,
      );
      expect(decrypted, plaintext);
    },
  );

  test('tampered ciphertext never materializes plaintext', () async {
    final encrypted = await cipher.encryptChunk(
      plaintext: utf8.encode('sensitive plaintext marker'),
      fileKey: key,
      header: header,
      fileVersionId: versionId,
      chunkNumber: 0,
      totalChunks: 1,
    );
    encrypted[0] ^= 1;
    await expectLater(
      cipher.decryptChunk(
        ciphertextFrame: encrypted,
        fileKey: key,
        header: header,
        fileVersionId: versionId,
        chunkNumber: 0,
        totalChunks: 1,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('AAD binds chunk order and total count', () async {
    final encrypted = await cipher.encryptChunk(
      plaintext: const [1, 2, 3],
      fileKey: key,
      header: header,
      fileVersionId: versionId,
      chunkNumber: 0,
      totalChunks: 2,
    );
    await expectLater(
      cipher.decryptChunk(
        ciphertextFrame: encrypted,
        fileKey: key,
        header: header,
        fileVersionId: versionId,
        chunkNumber: 1,
        totalChunks: 2,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('short ciphertext frame is rejected before decryption', () async {
    await expectLater(
      cipher.decryptChunk(
        ciphertextFrame: const [1, 2, 3],
        fileKey: key,
        header: header,
        fileVersionId: versionId,
        chunkNumber: 0,
        totalChunks: 1,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
