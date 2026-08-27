import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int homeBoxE2eeProtocolVersion = 1;
const int homeBoxPlaintextChunkSize = 4 * 1024 * 1024;
const int homeBoxFileKeyLength = 32;
const int homeBoxNoncePrefixLength = 16;
const int homeBoxChunkMacLength = 16;

final class E2eeFileHeader {
  E2eeFileHeader({
    required this.protocolVersion,
    required Uint8List noncePrefix,
  }) : _noncePrefix = Uint8List.fromList(noncePrefix) {
    if (protocolVersion != homeBoxE2eeProtocolVersion) {
      throw ArgumentError.value(protocolVersion, 'protocolVersion');
    }
    if (_noncePrefix.length != homeBoxNoncePrefixLength) {
      throw ArgumentError.value(_noncePrefix.length, 'noncePrefix.length');
    }
  }

  static const List<int> _magic = [0x48, 0x42, 0x58, 0x46]; // HBXF

  final int protocolVersion;
  final Uint8List _noncePrefix;

  Uint8List get noncePrefix => Uint8List.fromList(_noncePrefix);

  Uint8List encode() {
    final result = Uint8List(_magic.length + 2 + _noncePrefix.length);
    result.setAll(0, _magic);
    ByteData.sublistView(result)
        .setUint16(_magic.length, protocolVersion, Endian.big);
    result.setAll(_magic.length + 2, _noncePrefix);
    return result;
  }

  factory E2eeFileHeader.decode(List<int> encoded) {
    if (encoded.length != _magic.length + 2 + homeBoxNoncePrefixLength) {
      throw const FormatException('Invalid HomeBox E2EE header length.');
    }
    for (var index = 0; index < _magic.length; index++) {
      if (encoded[index] != _magic[index]) {
        throw const FormatException('Invalid HomeBox E2EE header magic.');
      }
    }
    final bytes = Uint8List.fromList(encoded);
    return E2eeFileHeader(
      protocolVersion: ByteData.sublistView(bytes)
          .getUint16(_magic.length, Endian.big),
      noncePrefix: Uint8List.sublistView(bytes, _magic.length + 2),
    );
  }
}

final class E2eeFileCipher {
  E2eeFileCipher({Xchacha20? algorithm})
    : _algorithm = algorithm ?? Xchacha20.poly1305Aead();

  final Xchacha20 _algorithm;

  Future<SecretKey> newFileKey() => _algorithm.newSecretKey();

  E2eeFileHeader newHeader() {
    final nonce = _algorithm.newNonce();
    return E2eeFileHeader(
      protocolVersion: homeBoxE2eeProtocolVersion,
      noncePrefix: Uint8List.fromList(
        nonce.take(homeBoxNoncePrefixLength).toList(),
      ),
    );
  }

  Future<Uint8List> encryptChunk({
    required List<int> plaintext,
    required SecretKey fileKey,
    required E2eeFileHeader header,
    required Uint8List fileVersionId,
    required int chunkNumber,
    required int totalChunks,
  }) async {
    _validateChunkArguments(
      plaintextLength: plaintext.length,
      fileVersionId: fileVersionId,
      chunkNumber: chunkNumber,
      totalChunks: totalChunks,
    );
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: fileKey,
      nonce: _nonce(header, chunkNumber),
      aad: _aad(header, fileVersionId, chunkNumber, totalChunks),
    );
    return Uint8List.fromList(box.concatenation(nonce: false));
  }

  Future<Uint8List> decryptChunk({
    required List<int> ciphertextFrame,
    required SecretKey fileKey,
    required E2eeFileHeader header,
    required Uint8List fileVersionId,
    required int chunkNumber,
    required int totalChunks,
  }) async {
    if (ciphertextFrame.length < homeBoxChunkMacLength) {
      throw const FormatException(
        'Ciphertext frame is shorter than its authentication tag.',
      );
    }
    _validateChunkArguments(
      plaintextLength: ciphertextFrame.length - homeBoxChunkMacLength,
      fileVersionId: fileVersionId,
      chunkNumber: chunkNumber,
      totalChunks: totalChunks,
    );
    final parsed = SecretBox.fromConcatenation(
      ciphertextFrame,
      nonceLength: 0,
      macLength: homeBoxChunkMacLength,
    );
    final box = SecretBox(
      parsed.cipherText,
      nonce: _nonce(header, chunkNumber),
      mac: parsed.mac,
    );
    final plaintext = await _algorithm.decrypt(
      box,
      secretKey: fileKey,
      aad: _aad(header, fileVersionId, chunkNumber, totalChunks),
    );
    return Uint8List.fromList(plaintext);
  }

  Uint8List _nonce(E2eeFileHeader header, int chunkNumber) {
    final nonce = Uint8List(_algorithm.nonceLength);
    nonce.setAll(0, header.noncePrefix);
    ByteData.sublistView(nonce)
        .setUint64(homeBoxNoncePrefixLength, chunkNumber, Endian.big);
    return nonce;
  }

  Uint8List _aad(
    E2eeFileHeader header,
    Uint8List fileVersionId,
    int chunkNumber,
    int totalChunks,
  ) {
    final aad = Uint8List(4 + 2 + 16 + 8 + 8);
    aad.setAll(0, const [0x48, 0x42, 0x58, 0x43]); // HBXC
    final data = ByteData.sublistView(aad);
    data.setUint16(4, header.protocolVersion, Endian.big);
    aad.setAll(6, fileVersionId);
    data.setUint64(22, chunkNumber, Endian.big);
    data.setUint64(30, totalChunks, Endian.big);
    return aad;
  }

  void _validateChunkArguments({
    required int plaintextLength,
    required Uint8List fileVersionId,
    required int chunkNumber,
    required int totalChunks,
  }) {
    if (fileVersionId.length != 16) {
      throw ArgumentError.value(fileVersionId.length, 'fileVersionId.length');
    }
    if (totalChunks < 1 || chunkNumber < 0 || chunkNumber >= totalChunks) {
      throw ArgumentError(
        'Chunk number must be within the declared chunk count.',
      );
    }
    if (plaintextLength < 0 || plaintextLength > homeBoxPlaintextChunkSize) {
      throw ArgumentError.value(plaintextLength, 'plaintextLength');
    }
  }
}
