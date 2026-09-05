import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'opaque_id.dart';

const int homeBoxDeviceKeySignatureVersion = 1;

/// A certificate proving that an account's Ed25519 identity approved one
/// exact X25519 device key. The server may relay this value but cannot forge
/// it because the signing identity is derived only on vault-unlocked clients.
final class DeviceKeyCertificate {
  DeviceKeyCertificate({
    required this.signatureVersion,
    required this.deviceKeyVersion,
    required List<int> accountIdentityPublicKey,
    required List<int> signature,
  }) : accountIdentityPublicKey = Uint8List.fromList(accountIdentityPublicKey),
       signature = Uint8List.fromList(signature);

  final int signatureVersion;
  final int deviceKeyVersion;
  final Uint8List accountIdentityPublicKey;
  final Uint8List signature;
}

/// Stable account signing identity derived from the Vault Key with
/// domain-separated HKDF. Existing trusted devices already possess that key,
/// so this adds authenticated device certificates without migrating or
/// synchronizing another private secret.
final class AccountIdentity {
  AccountIdentity._(this._keyPair, this._algorithm);

  static const List<int> _derivationInfo = <int>[
    0x48,
    0x42,
    0x58,
    0x2d,
    0x41,
    0x43,
    0x43,
    0x4f,
    0x55,
    0x4e,
    0x54,
    0x2d,
    0x49,
    0x44,
    0x2d,
    0x56,
    0x31,
  ]; // HBX-ACCOUNT-ID-V1

  final SimpleKeyPairData _keyPair;
  final Ed25519 _algorithm;

  static Future<AccountIdentity> derive({
    required SecretKey vaultKey,
    required String accountId,
    Ed25519? algorithm,
  }) async {
    final accountIdBytes = uuidStringToBytes(accountId);
    late final SecretKey derived;
    try {
      derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: vaultKey,
        nonce: accountIdBytes,
        info: _derivationInfo,
      );
    } finally {
      accountIdBytes.fillRange(0, accountIdBytes.length, 0);
    }
    late final Uint8List seed;
    try {
      seed = Uint8List.fromList(await derived.extractBytes());
    } finally {
      derived.destroy();
    }
    final signer = algorithm ?? Ed25519();
    try {
      final keyPair = await signer.newKeyPairFromSeed(seed);
      return AccountIdentity._(await keyPair.extract(), signer);
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  SimplePublicKey get publicKey {
    if (_keyPair.hasBeenDestroyed) {
      throw StateError('Account identity has been destroyed.');
    }
    return SimplePublicKey(
      Uint8List.fromList(_keyPair.publicKey.bytes),
      type: KeyPairType.ed25519,
    );
  }

  Future<DeviceKeyCertificate> certifyDevice({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required List<int> devicePublicKey,
  }) async {
    final statement = deviceKeyStatement(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: deviceKeyVersion,
      devicePublicKey: devicePublicKey,
    );
    late final Signature signed;
    try {
      signed = await _algorithm.sign(statement, keyPair: _keyPair);
    } finally {
      statement.fillRange(0, statement.length, 0);
    }
    return DeviceKeyCertificate(
      signatureVersion: homeBoxDeviceKeySignatureVersion,
      deviceKeyVersion: deviceKeyVersion,
      accountIdentityPublicKey: publicKey.bytes,
      signature: signed.bytes,
    );
  }

  Future<bool> verifyDevice({
    required DeviceKeyCertificate certificate,
    required String accountId,
    required String deviceId,
    required List<int> devicePublicKey,
  }) async {
    if (certificate.signatureVersion != homeBoxDeviceKeySignatureVersion ||
        certificate.accountIdentityPublicKey.length != 32 ||
        certificate.signature.length != 64 ||
        !_constantTimeEquals(
          certificate.accountIdentityPublicKey,
          publicKey.bytes,
        )) {
      return false;
    }
    final statement = deviceKeyStatement(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: certificate.deviceKeyVersion,
      devicePublicKey: devicePublicKey,
    );
    try {
      return await _algorithm.verify(
        statement,
        signature: Signature(
          certificate.signature,
          publicKey: SimplePublicKey(
            certificate.accountIdentityPublicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } finally {
      statement.fillRange(0, statement.length, 0);
    }
  }

  void destroy() => _keyPair.destroy();
}

Uint8List deviceKeyStatement({
  required String accountId,
  required String deviceId,
  required int deviceKeyVersion,
  required List<int> devicePublicKey,
}) {
  if (deviceKeyVersion < 1 || deviceKeyVersion > 0xffffffff) {
    throw ArgumentError.value(deviceKeyVersion, 'deviceKeyVersion');
  }
  if (devicePublicKey.length != 32) {
    throw ArgumentError.value(devicePublicKey.length, 'devicePublicKey.length');
  }
  final accountIdBytes = uuidStringToBytes(accountId);
  final deviceIdBytes = uuidStringToBytes(deviceId);
  final result = Uint8List(75);
  result.setAll(0, const [0x48, 0x42, 0x58, 0x44, 0x53]); // HBXDS
  final data = ByteData.sublistView(result);
  data.setUint16(5, homeBoxDeviceKeySignatureVersion, Endian.big);
  result.setAll(7, accountIdBytes);
  result.setAll(23, deviceIdBytes);
  data.setUint32(39, deviceKeyVersion, Endian.big);
  result.setAll(43, devicePublicKey);
  accountIdBytes.fillRange(0, accountIdBytes.length, 0);
  deviceIdBytes.fillRange(0, deviceIdBytes.length, 0);
  return result;
}

Future<String> devicePublicKeyFingerprint(List<int> publicKey) async {
  if (publicKey.length != 32) {
    throw ArgumentError.value(publicKey.length, 'publicKey.length');
  }
  final digest = await Sha256().hash(publicKey);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(':')
      .toUpperCase();
}

Future<Uint8List> deviceCertificateBinding(
  DeviceKeyCertificate certificate,
) async {
  if (certificate.signatureVersion != homeBoxDeviceKeySignatureVersion ||
      certificate.deviceKeyVersion < 1 ||
      certificate.deviceKeyVersion > 0xffffffff ||
      certificate.accountIdentityPublicKey.length != 32 ||
      certificate.signature.length != 64) {
    throw const FormatException('Invalid device key certificate shape.');
  }
  final encoded = Uint8List(5 + 2 + 4 + 32 + 64);
  encoded.setAll(0, const [0x48, 0x42, 0x58, 0x43, 0x42]); // HBXCB
  final data = ByteData.sublistView(encoded);
  data.setUint16(5, certificate.signatureVersion, Endian.big);
  data.setUint32(7, certificate.deviceKeyVersion, Endian.big);
  encoded.setAll(11, certificate.accountIdentityPublicKey);
  encoded.setAll(43, certificate.signature);
  try {
    final digest = await Sha256().hash(encoded);
    return Uint8List.fromList(digest.bytes);
  } finally {
    encoded.fillRange(0, encoded.length, 0);
  }
}

/// Payload suitable for a QR encoder or clipboard transfer during pairing.
/// The approving client still compares it with the signed-in device record.
String devicePairingPayload({
  required String deviceId,
  required int keyVersion,
  required List<int> publicKey,
}) {
  final deviceIdBytes = uuidStringToBytes(deviceId);
  deviceIdBytes.fillRange(0, deviceIdBytes.length, 0);
  if (keyVersion < 1 || keyVersion > 0xffffffff) {
    throw ArgumentError.value(keyVersion, 'keyVersion');
  }
  if (publicKey.length != 32) {
    throw ArgumentError.value(publicKey.length, 'publicKey.length');
  }
  final encodedKey = base64UrlEncode(publicKey).replaceAll('=', '');
  return 'homebox://pair-device?v=1&id=$deviceId&kv=$keyVersion&key=$encodedKey';
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
