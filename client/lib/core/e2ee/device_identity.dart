import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String homeBoxDevicePrivateKeyStorageKey =
    'homebox.e2ee.device.x25519.private.v1';
const int homeBoxDeviceKeyVersion = 1;

abstract interface class DevicePrivateKeyStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class PlatformDevicePrivateKeyStorage implements DevicePrivateKeyStorage {
  const PlatformDevicePrivateKeyStorage([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class DeviceIdentity {
  DeviceIdentity._(this._keyPair);

  final SimpleKeyPairData _keyPair;

  SimpleKeyPair get keyPair {
    if (_keyPair.hasBeenDestroyed) {
      throw StateError('Device identity has been destroyed.');
    }
    return _keyPair;
  }

  SimplePublicKey get publicKey {
    if (_keyPair.hasBeenDestroyed) {
      throw StateError('Device identity has been destroyed.');
    }
    return SimplePublicKey(
      Uint8List.fromList(_keyPair.publicKey.bytes),
      type: KeyPairType.x25519,
    );
  }

  void destroy() => _keyPair.destroy();

  @override
  String toString() =>
      'DeviceIdentity(publicKey: ${publicKey.bytes.length} bytes)';
}

final class DeviceIdentityStore {
  DeviceIdentityStore(this._storage, {X25519? keyExchange})
    : _keyExchange = keyExchange ?? X25519();

  factory DeviceIdentityStore.platform() =>
      DeviceIdentityStore(const PlatformDevicePrivateKeyStorage());

  static const String _encodedPrefix = 'HBXD1-';

  final DevicePrivateKeyStorage _storage;
  final X25519 _keyExchange;

  Future<DeviceIdentity?> load() async {
    final encoded = await _storage.read(homeBoxDevicePrivateKeyStorageKey);
    if (encoded == null) return null;
    return _decode(encoded);
  }

  Future<DeviceIdentity> loadOrCreate() async {
    final existing = await _storage.read(homeBoxDevicePrivateKeyStorageKey);
    if (existing != null) return _decode(existing);

    final generated = await _keyExchange.newKeyPair();
    final keyPair = await generated.extract();
    final privateKey = Uint8List.fromList(keyPair.bytes);
    try {
      final encoded =
          '$_encodedPrefix${base64Url.encode(privateKey).replaceAll('=', '')}';
      await _storage.write(homeBoxDevicePrivateKeyStorageKey, encoded);
      return DeviceIdentity._(keyPair);
    } catch (_) {
      keyPair.destroy();
      rethrow;
    } finally {
      privateKey.fillRange(0, privateKey.length, 0);
    }
  }

  Future<void> clear() => _storage.delete(homeBoxDevicePrivateKeyStorageKey);

  Future<DeviceIdentity> _decode(String encoded) async {
    if (!encoded.startsWith(_encodedPrefix)) {
      throw const FormatException('Invalid HomeBox device key prefix.');
    }
    final payload = encoded.substring(_encodedPrefix.length);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(payload)) {
      throw const FormatException('Invalid HomeBox device key encoding.');
    }

    final privateKey = Uint8List.fromList(base64Url.decode('$payload='));
    try {
      if (privateKey.length != 32) {
        throw const FormatException('Invalid HomeBox device key length.');
      }
      final keyPair = await _keyExchange.newKeyPairFromSeed(privateKey);
      return DeviceIdentity._(await keyPair.extract());
    } finally {
      privateKey.fillRange(0, privateKey.length, 0);
    }
  }
}
