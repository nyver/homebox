import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int homeBoxRecoveryVersion = 1;
const int homeBoxRecoverySecretLength = 32;
const int homeBoxRecoverySaltLength = 16;
const int homeBoxRecoveryNonceLength = 24;
const int homeBoxRecoveryMacLength = 16;
const int homeBoxRecoveryMemoryKiB = 19 * 1024;
const int homeBoxRecoveryIterations = 2;
const int homeBoxRecoveryParallelism = 1;

final class RecoverySecret {
  RecoverySecret._(this._material);

  static const String prefix = 'HBXR1-';
  final SecretKeyData _material;

  factory RecoverySecret.generate() => RecoverySecret._(
    SecretKeyData.random(
      length: homeBoxRecoverySecretLength,
      debugLabel: 'HomeBox Recovery Secret',
    ),
  );

  factory RecoverySecret.parse(String encoded) {
    if (!encoded.startsWith(prefix)) {
      throw const FormatException('Invalid HomeBox Recovery Secret prefix.');
    }
    final payload = encoded.substring(prefix.length);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(payload)) {
      throw const FormatException('Invalid HomeBox Recovery Secret encoding.');
    }
    final bytes = base64Url.decode('$payload=');
    if (bytes.length != homeBoxRecoverySecretLength) {
      throw const FormatException('Invalid HomeBox Recovery Secret length.');
    }
    return RecoverySecret._(
      SecretKeyData(
        bytes,
        overwriteWhenDestroyed: true,
        debugLabel: 'HomeBox Recovery Secret',
      ),
    );
  }

  Future<String> export() async {
    final bytes = Uint8List.fromList(await _material.extractBytes());
    try {
      return '$prefix${base64Url.encode(bytes).replaceAll('=', '')}';
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void destroy() => _material.destroy();
}

final class RecoveryPackage {
  RecoveryPackage({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    required List<int> salt,
    required List<int> nonce,
    required List<int> ciphertext,
    required List<int> mac,
  }) : _salt = Uint8List.fromList(salt),
       _nonce = Uint8List.fromList(nonce),
       _ciphertext = Uint8List.fromList(ciphertext),
       _mac = Uint8List.fromList(mac) {
    _validateParameters(memoryKiB, iterations, parallelism);
    if (_salt.length != homeBoxRecoverySaltLength ||
        _nonce.length != homeBoxRecoveryNonceLength ||
        _ciphertext.length != 32 ||
        _mac.length != homeBoxRecoveryMacLength) {
      throw ArgumentError('Invalid recovery package component length.');
    }
  }

  static const List<int> _magic = [0x48, 0x42, 0x58, 0x52]; // HBXR
  static const int encodedLength = 107;

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final Uint8List _salt;
  final Uint8List _nonce;
  final Uint8List _ciphertext;
  final Uint8List _mac;

  Uint8List encode() {
    final result = Uint8List(encodedLength);
    result.setAll(0, _magic);
    final data = ByteData.sublistView(result);
    data.setUint16(4, homeBoxRecoveryVersion, Endian.big);
    data.setUint32(6, memoryKiB, Endian.big);
    data.setUint32(10, iterations, Endian.big);
    data.setUint8(14, parallelism);
    result.setAll(15, _salt);
    result.setAll(31, _nonce);
    data.setUint32(55, _ciphertext.length, Endian.big);
    result.setAll(59, _ciphertext);
    result.setAll(91, _mac);
    return result;
  }

  factory RecoveryPackage.decode(List<int> encoded) {
    if (encoded.length != encodedLength) {
      throw const FormatException('Invalid HomeBox recovery package length.');
    }
    final bytes = Uint8List.fromList(encoded);
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) {
        throw const FormatException('Invalid HomeBox recovery package magic.');
      }
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint16(4, Endian.big);
    if (version != homeBoxRecoveryVersion) {
      throw FormatException('Unsupported recovery package version: $version.');
    }
    final memoryKiB = data.getUint32(6, Endian.big);
    final iterations = data.getUint32(10, Endian.big);
    final parallelism = data.getUint8(14);
    try {
      _validateParameters(memoryKiB, iterations, parallelism);
    } on ArgumentError {
      throw const FormatException('Unsafe recovery package KDF parameters.');
    }
    if (data.getUint32(55, Endian.big) != 32) {
      throw const FormatException(
        'Invalid recovery package ciphertext length.',
      );
    }
    return RecoveryPackage(
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      salt: Uint8List.sublistView(bytes, 15, 31),
      nonce: Uint8List.sublistView(bytes, 31, 55),
      ciphertext: Uint8List.sublistView(bytes, 59, 91),
      mac: Uint8List.sublistView(bytes, 91, 107),
    );
  }

  static void _validateParameters(
    int memoryKiB,
    int iterations,
    int parallelism,
  ) {
    if (memoryKiB < homeBoxRecoveryMemoryKiB ||
        memoryKiB > 64 * 1024 ||
        iterations < homeBoxRecoveryIterations ||
        iterations > 4 ||
        parallelism < 1 ||
        parallelism > 4) {
      throw ArgumentError(
        'Recovery package KDF parameters are outside safe bounds.',
      );
    }
  }
}

final class RecoveryPackageCipher {
  RecoveryPackageCipher({Xchacha20? cipher})
    : _cipher = cipher ?? Xchacha20.poly1305Aead();

  final Xchacha20 _cipher;

  Future<RecoveryPackage> create({
    required RecoverySecret recoverySecret,
    required SecretKey userMasterKey,
    required Uint8List userId,
  }) async {
    _validateUserId(userId);
    final salt = Uint8List.fromList(
      _cipher.newNonce().take(homeBoxRecoverySaltLength).toList(),
    );
    final nonce = _cipher.newNonce();
    final derivedKey = await _deriveKey(
      recoverySecret,
      salt,
      homeBoxRecoveryMemoryKiB,
      homeBoxRecoveryIterations,
      homeBoxRecoveryParallelism,
    );
    final masterKeyBytes = Uint8List.fromList(
      await userMasterKey.extractBytes(),
    );
    try {
      if (masterKeyBytes.length != 32) {
        throw ArgumentError.value(
          masterKeyBytes.length,
          'userMasterKey.length',
        );
      }
      final box = await _cipher.encrypt(
        masterKeyBytes,
        secretKey: derivedKey,
        nonce: nonce,
        aad: _aad(
          userId,
          homeBoxRecoveryMemoryKiB,
          homeBoxRecoveryIterations,
          homeBoxRecoveryParallelism,
          salt,
        ),
      );
      return RecoveryPackage(
        memoryKiB: homeBoxRecoveryMemoryKiB,
        iterations: homeBoxRecoveryIterations,
        parallelism: homeBoxRecoveryParallelism,
        salt: salt,
        nonce: nonce,
        ciphertext: box.cipherText,
        mac: box.mac.bytes,
      );
    } finally {
      masterKeyBytes.fillRange(0, masterKeyBytes.length, 0);
      derivedKey.destroy();
    }
  }

  Future<SecretKey> restore({
    required RecoverySecret recoverySecret,
    required RecoveryPackage recoveryPackage,
    required Uint8List userId,
  }) async {
    _validateUserId(userId);
    final derivedKey = await _deriveKey(
      recoverySecret,
      recoveryPackage._salt,
      recoveryPackage.memoryKiB,
      recoveryPackage.iterations,
      recoveryPackage.parallelism,
    );
    try {
      final plaintext = await _cipher.decrypt(
        SecretBox(
          recoveryPackage._ciphertext,
          nonce: recoveryPackage._nonce,
          mac: Mac(recoveryPackage._mac),
        ),
        secretKey: derivedKey,
        aad: _aad(
          userId,
          recoveryPackage.memoryKiB,
          recoveryPackage.iterations,
          recoveryPackage.parallelism,
          recoveryPackage._salt,
        ),
      );
      try {
        if (plaintext.length != 32) {
          throw const FormatException(
            'Recovered master key has an invalid length.',
          );
        }
        return await _cipher.newSecretKeyFromBytes(plaintext);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    } finally {
      derivedKey.destroy();
    }
  }

  Future<SecretKey> _deriveKey(
    RecoverySecret recoverySecret,
    List<int> salt,
    int memoryKiB,
    int iterations,
    int parallelism,
  ) => Argon2id(
    parallelism: parallelism,
    memory: memoryKiB,
    iterations: iterations,
    hashLength: 32,
  ).deriveKey(secretKey: recoverySecret._material, nonce: salt);

  Uint8List _aad(
    Uint8List userId,
    int memoryKiB,
    int iterations,
    int parallelism,
    List<int> salt,
  ) {
    final result = Uint8List(4 + 2 + 4 + 4 + 1 + 16 + 16);
    result.setAll(0, const [0x48, 0x42, 0x58, 0x50]); // HBXP
    final data = ByteData.sublistView(result);
    data.setUint16(4, homeBoxRecoveryVersion, Endian.big);
    data.setUint32(6, memoryKiB, Endian.big);
    data.setUint32(10, iterations, Endian.big);
    data.setUint8(14, parallelism);
    result.setAll(15, userId);
    result.setAll(31, salt);
    return result;
  }

  void _validateUserId(Uint8List userId) {
    if (userId.length != 16) {
      throw ArgumentError.value(userId.length, 'userId.length');
    }
  }
}
