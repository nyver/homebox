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

  test('splitChunkFrames reconstructs frame boundaries and round-trips through decrypt', () async {
    const plaintextChunkSize = 8; // small size so the test doesn't need megabytes of data
    final plaintexts = [
      List<int>.generate(plaintextChunkSize, (i) => i),
      List<int>.generate(plaintextChunkSize, (i) => 100 + i),
      List<int>.generate(3, (i) => 200 + i), // shorter last chunk
    ];
    final frames = <int>[];
    for (var i = 0; i < plaintexts.length; i++) {
      frames.addAll(await cipher.encryptChunk(
        plaintext: plaintexts[i],
        fileKey: key,
        header: header,
        fileVersionId: versionId,
        chunkNumber: i,
        totalChunks: plaintexts.length,
      ));
    }

    final split = splitChunkFrames(
      Uint8List.fromList(frames),
      chunkCount: plaintexts.length,
      plaintextChunkSize: plaintextChunkSize,
    );
    expect(split, hasLength(plaintexts.length));

    for (var i = 0; i < plaintexts.length; i++) {
      final decrypted = await cipher.decryptChunk(
        ciphertextFrame: split[i],
        fileKey: key,
        header: header,
        fileVersionId: versionId,
        chunkNumber: i,
        totalChunks: plaintexts.length,
      );
      expect(decrypted, plaintexts[i]);
    }
  });

  test('splitChunkFrames rejects a blob whose length disagrees with chunkCount', () {
    expect(
      () => splitChunkFrames(Uint8List.fromList(const [1, 2, 3]), chunkCount: 3, plaintextChunkSize: 8),
      throwsFormatException,
    );
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
