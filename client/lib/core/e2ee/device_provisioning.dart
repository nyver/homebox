import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_envelope.dart';

const int homeBoxLegacyDeviceProvisioningVersion = 1;
const int homeBoxDeviceProvisioningVersion = 2;
const int homeBoxDeviceProvisioningSaltLength = 16;

final class DeviceProvisioningEnvelope {
  DeviceProvisioningEnvelope({
    required SimplePublicKey ephemeralPublicKey,
    required List<int> salt,
    required this.wrappedVaultKey,
    this.protocolVersion = homeBoxDeviceProvisioningVersion,
  }) : _ephemeralPublicKey = _copyX25519PublicKey(ephemeralPublicKey),
       _salt = Uint8List.fromList(salt) {
    if (protocolVersion != homeBoxLegacyDeviceProvisioningVersion &&
        protocolVersion != homeBoxDeviceProvisioningVersion) {
      throw ArgumentError.value(protocolVersion, 'protocolVersion');
    }
    if (_salt.length != homeBoxDeviceProvisioningSaltLength) {
      throw ArgumentError.value(_salt.length, 'salt.length');
    }
    if (wrappedVaultKey.purpose != KeyEnvelopePurpose.deviceProvisioning) {
      throw ArgumentError.value(
        wrappedVaultKey.purpose,
        'wrappedVaultKey.purpose',
      );
    }
  }

  static const List<int> _magic = [0x48, 0x42, 0x58, 0x44]; // HBXD
  static const int encodedLength = 4 + 2 + 32 + 16 + KeyEnvelope.encodedLength;

  final SimplePublicKey _ephemeralPublicKey;
  final Uint8List _salt;
  final KeyEnvelope wrappedVaultKey;
  final int protocolVersion;

  int get keyVersion => wrappedVaultKey.keyVersion;

  SimplePublicKey get ephemeralPublicKey =>
      _copyX25519PublicKey(_ephemeralPublicKey);

  Uint8List encode() {
    final result = Uint8List(encodedLength);
    result.setAll(0, _magic);
    ByteData.sublistView(result).setUint16(4, protocolVersion, Endian.big);
    result.setAll(6, _ephemeralPublicKey.bytes);
    result.setAll(38, _salt);
    result.setAll(54, wrappedVaultKey.encode());
    return result;
  }

  factory DeviceProvisioningEnvelope.decode(List<int> encoded) {
    if (encoded.length != encodedLength) {
      throw const FormatException(
        'Invalid HomeBox device provisioning envelope length.',
      );
    }
    final bytes = Uint8List.fromList(encoded);
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) {
        throw const FormatException(
          'Invalid HomeBox device provisioning envelope magic.',
        );
      }
    }
    final version = ByteData.sublistView(bytes).getUint16(4, Endian.big);
    if (version != homeBoxLegacyDeviceProvisioningVersion &&
        version != homeBoxDeviceProvisioningVersion) {
      throw FormatException(
        'Unsupported device provisioning envelope version: $version.',
      );
    }

    final wrappedVaultKey = KeyEnvelope.decode(
      Uint8List.sublistView(bytes, 54, encodedLength),
    );
    if (wrappedVaultKey.purpose != KeyEnvelopePurpose.deviceProvisioning) {
      throw const FormatException(
        'Device provisioning envelope has an invalid key purpose.',
      );
    }
    return DeviceProvisioningEnvelope(
      ephemeralPublicKey: SimplePublicKey(
        Uint8List.sublistView(bytes, 6, 38),
        type: KeyPairType.x25519,
      ),
      salt: Uint8List.sublistView(bytes, 38, 54),
      wrappedVaultKey: wrappedVaultKey,
      protocolVersion: version,
    );
  }
}

final class DeviceProvisioningCipher {
  DeviceProvisioningCipher({
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

  Future<DeviceProvisioningEnvelope> create({
    required SecretKey vaultKey,
    required int keyVersion,
    required Uint8List vaultId,
    required Uint8List recipientDeviceId,
    required SimplePublicKey recipientPublicKey,
    Uint8List? certificateBinding,
  }) async {
    _validateContext(vaultId, recipientDeviceId, keyVersion);
    _validateX25519PublicKey(recipientPublicKey);
    final protocolVersion = certificateBinding == null
        ? homeBoxLegacyDeviceProvisioningVersion
        : homeBoxDeviceProvisioningVersion;
    _validateCertificateBinding(protocolVersion, certificateBinding);

    final ephemeralKeyPair = await _keyExchange.newKeyPair();
    try {
      final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
      final saltMaterial = SecretKeyData.random(
        length: homeBoxDeviceProvisioningSaltLength,
        debugLabel: 'HomeBox provisioning salt',
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
          vaultId: vaultId,
          recipientDeviceId: recipientDeviceId,
          ephemeralPublicKey: ephemeralPublicKey,
          salt: salt,
          protocolVersion: protocolVersion,
          certificateBinding: certificateBinding,
        );
        try {
          final wrappedVaultKey = await _keyEnvelopeCipher.wrapKey(
            wrappingKey: wrappingKey,
            keyToWrap: vaultKey,
            purpose: KeyEnvelopePurpose.deviceProvisioning,
            keyVersion: keyVersion,
            scopeId: vaultId,
            subjectId: recipientDeviceId,
          );
          return DeviceProvisioningEnvelope(
            ephemeralPublicKey: ephemeralPublicKey,
            salt: salt,
            wrappedVaultKey: wrappedVaultKey,
            protocolVersion: protocolVersion,
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
    required DeviceProvisioningEnvelope envelope,
    required SimpleKeyPair recipientKeyPair,
    required Uint8List vaultId,
    required Uint8List recipientDeviceId,
    Uint8List? certificateBinding,
  }) async {
    _validateContext(vaultId, recipientDeviceId, envelope.keyVersion);
    _validateCertificateBinding(envelope.protocolVersion, certificateBinding);
    final wrappingKey = await _deriveWrappingKey(
      keyPair: recipientKeyPair,
      remotePublicKey: envelope._ephemeralPublicKey,
      keyVersion: envelope.keyVersion,
      vaultId: vaultId,
      recipientDeviceId: recipientDeviceId,
      ephemeralPublicKey: envelope._ephemeralPublicKey,
      salt: envelope._salt,
      protocolVersion: envelope.protocolVersion,
      certificateBinding: certificateBinding,
    );
    try {
      return await _keyEnvelopeCipher.unwrapKey(
        wrappingKey: wrappingKey,
        envelope: envelope.wrappedVaultKey,
        scopeId: vaultId,
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
    required Uint8List vaultId,
    required Uint8List recipientDeviceId,
    required SimplePublicKey ephemeralPublicKey,
    required List<int> salt,
    required int protocolVersion,
    required Uint8List? certificateBinding,
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
      debugLabel: 'HomeBox X25519 shared secret',
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
          vaultId,
          recipientDeviceId,
          ephemeralPublicKey,
          salt,
          protocolVersion,
          certificateBinding,
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
        debugLabel: 'HomeBox provisioning wrapping key',
      );
    } finally {
      sharedSecret.destroy();
    }
  }

  Uint8List _keyDerivationInfo(
    int keyVersion,
    Uint8List vaultId,
    Uint8List recipientDeviceId,
    SimplePublicKey ephemeralPublicKey,
    List<int> salt,
    int protocolVersion,
    Uint8List? certificateBinding,
  ) {
    final result = Uint8List(
      4 +
          2 +
          4 +
          16 +
          16 +
          32 +
          16 +
          (protocolVersion == homeBoxDeviceProvisioningVersion ? 32 : 0),
    );
    result.setAll(0, const [0x48, 0x42, 0x58, 0x49]); // HBXI
    final data = ByteData.sublistView(result);
    data.setUint16(4, protocolVersion, Endian.big);
    data.setUint32(6, keyVersion, Endian.big);
    result.setAll(10, vaultId);
    result.setAll(26, recipientDeviceId);
    result.setAll(42, ephemeralPublicKey.bytes);
    result.setAll(74, salt);
    if (certificateBinding != null) {
      result.setAll(90, certificateBinding);
    }
    return result;
  }

  void _validateCertificateBinding(
    int protocolVersion,
    Uint8List? certificateBinding,
  ) {
    if (protocolVersion == homeBoxDeviceProvisioningVersion) {
      if (certificateBinding == null || certificateBinding.length != 32) {
        throw const FormatException(
          'Provisioning v2 requires a 32-byte device certificate binding.',
        );
      }
      return;
    }
    if (certificateBinding != null) {
      throw const FormatException(
        'Legacy provisioning must not include a device certificate binding.',
      );
    }
  }

  void _validateContext(
    Uint8List vaultId,
    Uint8List recipientDeviceId,
    int keyVersion,
  ) {
    if (vaultId.length != 16 || recipientDeviceId.length != 16) {
      throw ArgumentError(
        'Vault and recipient device IDs must be 16-byte opaque UUIDs.',
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
