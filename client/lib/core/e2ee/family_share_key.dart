import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_envelope.dart';

const int homeBoxFamilyShareEnvelopeVersion = 1;
const int homeBoxFamilyShareEnvelopeSaltLength = 16;

/// An opaque per-folder key envelope for exactly one recipient device.
///
/// The sender gives the encoded bytes to the server, which only stores and
/// returns them. The envelope does not contain a personal vault key.
final class FamilyShareKeyEnvelope {
  FamilyShareKeyEnvelope({
    required SimplePublicKey ephemeralPublicKey,
    required List<int> salt,
    required this.wrappedFolderKey,
  }) : _ephemeralPublicKey = _copyX25519PublicKey(ephemeralPublicKey),
       _salt = Uint8List.fromList(salt) {
    if (_salt.length != homeBoxFamilyShareEnvelopeSaltLength) {
      throw ArgumentError.value(_salt.length, 'salt.length');
    }
    if (wrappedFolderKey.purpose != KeyEnvelopePurpose.familyShare) {
      throw ArgumentError.value(
        wrappedFolderKey.purpose,
        'wrappedFolderKey.purpose',
      );
    }
  }

  static const List<int> _magic = [0x48, 0x42, 0x58, 0x46]; // HBXF
  static const int encodedLength = 4 + 2 + 32 + 16 + KeyEnvelope.encodedLength;

  final SimplePublicKey _ephemeralPublicKey;
  final Uint8List _salt;
  final KeyEnvelope wrappedFolderKey;

  int get keyVersion => wrappedFolderKey.keyVersion;

  SimplePublicKey get ephemeralPublicKey =>
      _copyX25519PublicKey(_ephemeralPublicKey);

  Uint8List encode() {
    final result = Uint8List(encodedLength);
    result.setAll(0, _magic);
    ByteData.sublistView(result)
        .setUint16(4, homeBoxFamilyShareEnvelopeVersion, Endian.big);
    result.setAll(6, _ephemeralPublicKey.bytes);
    result.setAll(38, _salt);
    result.setAll(54, wrappedFolderKey.encode());
    return result;
  }

  factory FamilyShareKeyEnvelope.decode(List<int> encoded) {
    if (encoded.length != encodedLength) {
      throw const FormatException(
        'Invalid HomeBox family share envelope length.',
      );
    }
    final bytes = Uint8List.fromList(encoded);
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) {
        throw const FormatException(
          'Invalid HomeBox family share envelope magic.',
        );
      }
    }
    final version = ByteData.sublistView(bytes).getUint16(4, Endian.big);
    if (version != homeBoxFamilyShareEnvelopeVersion) {
      throw FormatException(
        'Unsupported family share envelope version: $version.',
      );
    }
    final wrappedFolderKey = KeyEnvelope.decode(
      Uint8List.sublistView(bytes, 54, encodedLength),
    );
    if (wrappedFolderKey.purpose != KeyEnvelopePurpose.familyShare) {
      throw const FormatException(
        'Family share envelope has an invalid key purpose.',
      );
    }
    return FamilyShareKeyEnvelope(
      ephemeralPublicKey: SimplePublicKey(
        Uint8List.sublistView(bytes, 6, 38),
        type: KeyPairType.x25519,
      ),
      salt: Uint8List.sublistView(bytes, 38, 54),
      wrappedFolderKey: wrappedFolderKey,
    );
  }
}

/// Creates and opens device-specific per-folder key envelopes for Family Vault.
final class FamilyShareKeyCipher {
  FamilyShareKeyCipher({
    X25519? keyExchange,
    Hkdf? keyDerivation,
    KeyEnvelopeCipher? keyEnvelopeCipher,
  }) : _keyExchange = keyExchange ?? X25519(),
       _keyDerivation =
           keyDerivation ?? Hkdf(hmac: Hmac.sha256(), outputLength: 32),
       _keyEnvelopeCipher = keyEnvelopeCipher ?? KeyEnvelopeCipher();

  final X25519 _keyExchange;
  final Hkdf _keyDerivation;
  final KeyEnvelopeCipher _keyEnvelopeCipher;

  Future<FamilyShareKeyEnvelope> create({
    required SecretKey folderKey,
    required int keyVersion,
    required Uint8List folderId,
    required Uint8List ownerUserId,
    required Uint8List recipientUserId,
    required Uint8List recipientDeviceId,
    required SimplePublicKey recipientPublicKey,
  }) async {
    _validateContext(
      folderId,
      ownerUserId,
      recipientUserId,
      recipientDeviceId,
      keyVersion,
    );
    _validateX25519PublicKey(recipientPublicKey);

    final ephemeralKeyPair = await _keyExchange.newKeyPair();
    try {
      final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
      final saltMaterial = SecretKeyData.random(
        length: homeBoxFamilyShareEnvelopeSaltLength,
        debugLabel: 'HomeBox Family Vault envelope salt',
      );
      late final Uint8List salt;
      try {
        salt = Uint8List.fromList(await saltMaterial.extractBytes());
      } finally {
        saltMaterial.destroy();
      }
      try {
        final wrappingKey = await _deriveWrappingKey(
          keyPair: ephemeralKeyPair,
          remotePublicKey: recipientPublicKey,
          keyVersion: keyVersion,
          folderId: folderId,
          ownerUserId: ownerUserId,
          recipientUserId: recipientUserId,
          recipientDeviceId: recipientDeviceId,
          ephemeralPublicKey: ephemeralPublicKey,
          salt: salt,
        );
        try {
          final wrappedFolderKey = await _keyEnvelopeCipher.wrapKey(
            wrappingKey: wrappingKey,
            keyToWrap: folderKey,
            purpose: KeyEnvelopePurpose.familyShare,
            keyVersion: keyVersion,
            scopeId: folderId,
            subjectId: recipientDeviceId,
          );
          return FamilyShareKeyEnvelope(
            ephemeralPublicKey: ephemeralPublicKey,
            salt: salt,
            wrappedFolderKey: wrappedFolderKey,
          );
        } finally {
          wrappingKey.destroy();
        }
      } finally {
        salt.fillRange(0, salt.length, 0);
      }
    } finally {
      ephemeralKeyPair.destroy();
    }
  }

  Future<SecretKey> open({
    required FamilyShareKeyEnvelope envelope,
    required SimpleKeyPair recipientKeyPair,
    required Uint8List folderId,
    required Uint8List ownerUserId,
    required Uint8List recipientUserId,
    required Uint8List recipientDeviceId,
  }) async {
    _validateContext(
      folderId,
      ownerUserId,
      recipientUserId,
      recipientDeviceId,
      envelope.keyVersion,
    );
    final wrappingKey = await _deriveWrappingKey(
      keyPair: recipientKeyPair,
      remotePublicKey: envelope._ephemeralPublicKey,
      keyVersion: envelope.keyVersion,
      folderId: folderId,
      ownerUserId: ownerUserId,
      recipientUserId: recipientUserId,
      recipientDeviceId: recipientDeviceId,
      ephemeralPublicKey: envelope._ephemeralPublicKey,
      salt: envelope._salt,
    );
    try {
      return await _keyEnvelopeCipher.unwrapKey(
        wrappingKey: wrappingKey,
        envelope: envelope.wrappedFolderKey,
        scopeId: folderId,
        subjectId: recipientDeviceId,
      );
    } finally {
      wrappingKey.destroy();
    }
  }

  Future<SecretKey> _deriveWrappingKey({
    required KeyPair keyPair,
    required SimplePublicKey remotePublicKey,
    required int keyVersion,
    required Uint8List folderId,
    required Uint8List ownerUserId,
    required Uint8List recipientUserId,
    required Uint8List recipientDeviceId,
    required SimplePublicKey ephemeralPublicKey,
    required List<int> salt,
  }) async {
    final rawSharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );
    late final Uint8List sharedSecretBytes;
    try {
      sharedSecretBytes = Uint8List.fromList(
        await rawSharedSecret.extractBytes(),
      );
    } finally {
      rawSharedSecret.destroy();
    }
    final sharedSecret = SecretKeyData(
      sharedSecretBytes,
      overwriteWhenDestroyed: true,
      debugLabel: 'HomeBox Family Vault shared secret',
    );
    try {
      if (sharedSecretBytes.every((byte) => byte == 0)) {
        throw const FormatException('Invalid X25519 shared secret.');
      }
      final derivedKey = await _keyDerivation.deriveKey(
        secretKey: sharedSecret,
        nonce: salt,
        info: _keyDerivationInfo(
          keyVersion,
          folderId,
          ownerUserId,
          recipientUserId,
          recipientDeviceId,
          ephemeralPublicKey,
          salt,
        ),
      );
      late final Uint8List derivedKeyBytes;
      try {
        derivedKeyBytes = Uint8List.fromList(await derivedKey.extractBytes());
      } finally {
        derivedKey.destroy();
      }
      return SecretKeyData(
        derivedKeyBytes,
        overwriteWhenDestroyed: true,
        debugLabel: 'HomeBox Family Vault wrapping key',
      );
    } finally {
      sharedSecret.destroy();
    }
  }

  Uint8List _keyDerivationInfo(
    int keyVersion,
    Uint8List folderId,
    Uint8List ownerUserId,
    Uint8List recipientUserId,
    Uint8List recipientDeviceId,
    SimplePublicKey ephemeralPublicKey,
    List<int> salt,
  ) {
    final result = Uint8List(4 + 2 + 4 + 16 + 16 + 16 + 16 + 32 + 16);
    result.setAll(0, const [0x48, 0x42, 0x58, 0x53]); // HBXS
    final data = ByteData.sublistView(result);
    data.setUint16(4, homeBoxFamilyShareEnvelopeVersion, Endian.big);
    data.setUint32(6, keyVersion, Endian.big);
    result.setAll(10, folderId);
    result.setAll(26, ownerUserId);
    result.setAll(42, recipientUserId);
    result.setAll(58, recipientDeviceId);
    result.setAll(74, ephemeralPublicKey.bytes);
    result.setAll(106, salt);
    return result;
  }

  void _validateContext(
    Uint8List folderId,
    Uint8List ownerUserId,
    Uint8List recipientUserId,
    Uint8List recipientDeviceId,
    int keyVersion,
  ) {
    if (folderId.length != 16 ||
        ownerUserId.length != 16 ||
        recipientUserId.length != 16 ||
        recipientDeviceId.length != 16) {
      throw ArgumentError(
        'Folder, account, and recipient device IDs must be 16-byte opaque UUIDs.',
      );
    }
    if (keyVersion < 1 || keyVersion > 0xffffffff) {
      throw ArgumentError.value(keyVersion, 'keyVersion');
    }
  }
}

SimplePublicKey _copyX25519PublicKey(SimplePublicKey publicKey) {
  _validateX25519PublicKey(publicKey);
  return SimplePublicKey(
    Uint8List.fromList(publicKey.bytes),
    type: KeyPairType.x25519,
  );
}

void _validateX25519PublicKey(SimplePublicKey publicKey) {
  if (publicKey.type != KeyPairType.x25519 || publicKey.bytes.length != 32) {
    throw ArgumentError('Expected a 32-byte X25519 public key.');
  }
}
