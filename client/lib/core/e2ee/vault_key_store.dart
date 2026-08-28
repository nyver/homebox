import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'opaque_id.dart';
import 'recovery.dart';

/// The key version this client always uses for its personal vault key.
/// Rotation (issuing v2, v3, ...) is a later milestone (§10.11); nothing
/// here persists a version number yet because there is only ever one.
const int homeBoxPersonalVaultKeyVersion = 1;

abstract interface class VaultKeyStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class PlatformVaultKeyStorage implements VaultKeyStorage {
  const PlatformVaultKeyStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Bootstraps and persists this device's copy of the personal vault's key
/// hierarchy (ADR-011): a random User Master Key and a random Vault Key,
/// created together the first time a device sets up E2EE with no existing
/// trusted device or Recovery Secret to provision from. This is the missing
/// half of ADR-013's "during initial vault setup" — that ADR describes the
/// Recovery Secret/Package format; this class is what actually calls it to
/// create everything the first time.
///
/// Both keys are stored directly via OS-backed secure storage, the same way
/// `DeviceIdentityStore` stores the raw device private key: the OS secure
/// storage layer is what provides at-rest confidentiality here, so wrapping
/// the Vault Key with the UMK a second time before persisting it locally
/// would add no real protection. The `KeyEnvelope`/UMK-wrapping format
/// (ADR-011) is instead used for what it's actually for: the Recovery
/// Package, and delivering the Vault Key to a *different* device.
final class VaultKeyStore {
  VaultKeyStore([VaultKeyStorage? storage]) : _storage = storage ?? const PlatformVaultKeyStorage();

  static const String _userMasterKeyStorageKey = 'homebox.e2ee.vault.user_master_key.v1';
  static const String _vaultKeyStorageKey = 'homebox.e2ee.vault.key.v1';
  static const String _recoveryPackageStorageKey = 'homebox.e2ee.vault.recovery_package.v1';

  final VaultKeyStorage _storage;
  final Xchacha20 _algorithm = Xchacha20.poly1305Aead();

  Future<bool> exists() async => (await _storage.read(_vaultKeyStorageKey)) != null;

  /// Creates this device's vault for the first time: a random UMK and Vault
  /// Key, plus a Recovery Secret and its encrypted Recovery Package. Throws
  /// a [StateError] if a vault already exists locally — callers must check
  /// [exists] first, since creating a second vault would silently orphan
  /// any data already encrypted under the first one.
  ///
  /// Returns the newly generated [RecoverySecret]. The caller must show it
  /// to the user exactly once with an explicit confirmation step (spec
  /// §10.12) and then call [RecoverySecret.destroy] — this method does not
  /// retain it.
  Future<RecoverySecret> createVault({required String userId}) async {
    if (await exists()) {
      throw StateError('A vault already exists on this device.');
    }
    final userIdBytes = uuidStringToBytes(userId);
    final userMasterKey = SecretKeyData.random(length: 32, debugLabel: 'HomeBox User Master Key');
    SecretKeyData? vaultKey;
    RecoverySecret? recoverySecret;
    try {
      vaultKey = SecretKeyData.random(length: 32, debugLabel: 'HomeBox Vault Key');
      recoverySecret = RecoverySecret.generate();
      final package = await RecoveryPackageCipher().create(
        recoverySecret: recoverySecret,
        userMasterKey: userMasterKey,
        userId: userIdBytes,
      );

      await _persistSecretKey(_userMasterKeyStorageKey, userMasterKey);
      await _persistSecretKey(_vaultKeyStorageKey, vaultKey);
      await _storage.write(_recoveryPackageStorageKey, base64Encode(package.encode()));

      final result = recoverySecret;
      recoverySecret = null; // ownership transfers to the caller from here.
      return result;
    } finally {
      userMasterKey.destroy();
      vaultKey?.destroy();
      recoverySecret?.destroy();
    }
  }

  /// Restores a vault from a Recovery Package + Recovery Secret (spec
  /// §10.12/ADR-013), for a clean device that has no local vault yet. This
  /// recovers the UMK but not the original Vault Key: only the account's
  /// existing trusted devices possess it, so a clean-device recovery must
  /// still go through provisioning (ADR-012) to actually unlock content —
  /// this method alone leaves the vault key slot empty.
  Future<void> restoreUserMasterKeyFromRecovery({
    required String userId,
    required RecoverySecret recoverySecret,
    required RecoveryPackage recoveryPackage,
  }) async {
    final userMasterKey = await RecoveryPackageCipher().restore(
      recoverySecret: recoverySecret,
      recoveryPackage: recoveryPackage,
      userId: uuidStringToBytes(userId),
    );
    try {
      await _persistSecretKey(_userMasterKeyStorageKey, userMasterKey);
      await _storage.write(_recoveryPackageStorageKey, base64Encode(recoveryPackage.encode()));
    } finally {
      userMasterKey.destroy();
    }
  }

  Future<SecretKey?> loadVaultKey() => _loadSecretKey(_vaultKeyStorageKey);

  Future<SecretKey?> loadUserMasterKey() => _loadSecretKey(_userMasterKeyStorageKey);

  Future<RecoveryPackage?> loadRecoveryPackage() async {
    final encoded = await _storage.read(_recoveryPackageStorageKey);
    if (encoded == null) return null;
    return RecoveryPackage.decode(base64Decode(encoded));
  }

  Future<void> clear() async {
    await _storage.delete(_userMasterKeyStorageKey);
    await _storage.delete(_vaultKeyStorageKey);
    await _storage.delete(_recoveryPackageStorageKey);
  }

  Future<SecretKey?> _loadSecretKey(String storageKey) async {
    final encoded = await _storage.read(storageKey);
    if (encoded == null) return null;
    final bytes = Uint8List.fromList(base64Decode(encoded));
    try {
      return await _algorithm.newSecretKeyFromBytes(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _persistSecretKey(String storageKey, SecretKey secretKey) async {
    final bytes = Uint8List.fromList(await secretKey.extractBytes());
    try {
      await _storage.write(storageKey, base64Encode(bytes));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}
