import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int homeBoxKeyEnvelopeVersion = 1;
const int homeBoxWrappedKeyLength = 32;
const int homeBoxKeyEnvelopeNonceLength = 24;
const int homeBoxKeyEnvelopeMacLength = 16;

enum KeyEnvelopePurpose {
  fileKey(1),
  vaultKey(2),
  deviceProvisioning(3),
  recoveryKey(4);

  const KeyEnvelopePurpose(this.code);
  final int code;

  static KeyEnvelopePurpose fromCode(int code) => values.firstWhere(
    (value) => value.code == code,
    orElse: () => throw FormatException('Unknown key envelope purpose: $code.'),
  );
}

final class KeyEnvelope {
  KeyEnvelope({
    required this.purpose,
    required this.keyVersion,
    required List<int> nonce,
    required List<int> ciphertext,
    required List<int> mac,
  }) : _nonce = Uint8List.fromList(nonce),
       _ciphertext = Uint8List.fromList(ciphertext),
       _mac = Uint8List.fromList(mac) {
    if (keyVersion < 1 || keyVersion > 0xffffffff) {
      throw ArgumentError.value(keyVersion, 'keyVersion');
    }
    if (_nonce.length != homeBoxKeyEnvelopeNonceLength ||
        _ciphertext.length != homeBoxWrappedKeyLength ||
        _mac.length != homeBoxKeyEnvelopeMacLength) {
      throw ArgumentError('Invalid key envelope component length.');
    }
  }

  static const List<int> _magic = [0x48, 0x42, 0x58, 0x4b]; // HBXK
  static const int encodedLength = 4 + 2 + 1 + 4 + 24 + 32 + 16;

  final KeyEnvelopePurpose purpose;
  final int keyVersion;
  final Uint8List _nonce;
  final Uint8List _ciphertext;
  final Uint8List _mac;

  Uint8List encode() {
    final result = Uint8List(encodedLength);
    result.setAll(0, _magic);
    final data = ByteData.sublistView(result);
    data.setUint16(4, homeBoxKeyEnvelopeVersion, Endian.big);
    data.setUint8(6, purpose.code);
    data.setUint32(7, keyVersion, Endian.big);
    result.setAll(11, _nonce);
    result.setAll(35, _ciphertext);
    result.setAll(67, _mac);
    return result;
  }

  factory KeyEnvelope.decode(List<int> encoded) {
    if (encoded.length != encodedLength) {
      throw const FormatException('Invalid HomeBox key envelope length.');
    }
    final bytes = Uint8List.fromList(encoded);
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) {
        throw const FormatException('Invalid HomeBox key envelope magic.');
      }
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint16(4, Endian.big);
    if (version != homeBoxKeyEnvelopeVersion) {
      throw FormatException('Unsupported key envelope version: $version.');
    }
    final keyVersion = data.getUint32(7, Endian.big);
    if (keyVersion < 1) {
      throw const FormatException('Invalid key envelope key version.');
    }
    return KeyEnvelope(
      purpose: KeyEnvelopePurpose.fromCode(data.getUint8(6)),
      keyVersion: keyVersion,
      nonce: Uint8List.sublistView(bytes, 11, 35),
      ciphertext: Uint8List.sublistView(bytes, 35, 67),
      mac: Uint8List.sublistView(bytes, 67, encodedLength),
    );
  }
}

final class KeyEnvelopeCipher {
  KeyEnvelopeCipher({Xchacha20? algorithm})
    : _algorithm = algorithm ?? Xchacha20.poly1305Aead();

  final Xchacha20 _algorithm;

  Future<KeyEnvelope> wrapKey({
    required SecretKey wrappingKey,
    required SecretKey keyToWrap,
    required KeyEnvelopePurpose purpose,
    required int keyVersion,
    required Uint8List scopeId,
    required Uint8List subjectId,
  }) async {
    _validateIds(scopeId, subjectId);
    if (keyVersion < 1 || keyVersion > 0xffffffff) {
      throw ArgumentError.value(keyVersion, 'keyVersion');
    }
    final keyBytes = Uint8List.fromList(await keyToWrap.extractBytes());
    try {
      if (keyBytes.length != homeBoxWrappedKeyLength) {
        throw ArgumentError.value(keyBytes.length, 'keyToWrap.length');
      }
      final nonce = _algorithm.newNonce();
      final box = await _algorithm.encrypt(
        keyBytes,
        secretKey: wrappingKey,
        nonce: nonce,
        aad: _aad(purpose, keyVersion, scopeId, subjectId),
      );
      return KeyEnvelope(
        purpose: purpose,
        keyVersion: keyVersion,
        nonce: nonce,
        ciphertext: box.cipherText,
        mac: box.mac.bytes,
      );
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }

  Future<SecretKey> unwrapKey({
    required SecretKey wrappingKey,
    required KeyEnvelope envelope,
    required Uint8List scopeId,
    required Uint8List subjectId,
  }) async {
    _validateIds(scopeId, subjectId);
    final plaintext = await _algorithm.decrypt(
      SecretBox(
        envelope._ciphertext,
        nonce: envelope._nonce,
        mac: Mac(envelope._mac),
      ),
      secretKey: wrappingKey,
      aad: _aad(envelope.purpose, envelope.keyVersion, scopeId, subjectId),
    );
    try {
      if (plaintext.length != homeBoxWrappedKeyLength) {
        throw const FormatException('Unwrapped key has an invalid length.');
      }
      return await _algorithm.newSecretKeyFromBytes(plaintext);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  Uint8List _aad(
    KeyEnvelopePurpose purpose,
    int keyVersion,
    Uint8List scopeId,
    Uint8List subjectId,
  ) {
    final result = Uint8List(4 + 2 + 1 + 4 + 16 + 16);
    result.setAll(0, const [0x48, 0x42, 0x58, 0x41]); // HBXA
    final data = ByteData.sublistView(result);
    data.setUint16(4, homeBoxKeyEnvelopeVersion, Endian.big);
    data.setUint8(6, purpose.code);
    data.setUint32(7, keyVersion, Endian.big);
    result.setAll(11, scopeId);
    result.setAll(27, subjectId);
    return result;
  }

  void _validateIds(Uint8List scopeId, Uint8List subjectId) {
    if (scopeId.length != 16 || subjectId.length != 16) {
      throw ArgumentError(
        'Scope and subject IDs must be 16-byte opaque UUIDs.',
      );
    }
  }
}
