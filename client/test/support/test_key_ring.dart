import 'package:cryptography/cryptography.dart';
import 'package:homebox_client/core/e2ee/key_ring.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';

/// A key ring holding only [userId]'s personal Vault Key, for tests that
/// exercise content outside any shared folder.
OwnerKeyRing vaultOnlyKeyRing(SecretKey vaultKey, String userId) =>
    OwnerKeyRing(
      userId: userId,
      vaultKey: vaultKey,
      vaultKeyVersion: homeBoxPersonalVaultKeyVersion,
      wrappedFolderKeys: {},
    );

/// The personal Vault Key of [userId] as a [ScopedKey].
ScopedKey vaultScopedKey(SecretKey vaultKey, String userId) => ScopedKey(
  scopeId: userId,
  version: homeBoxPersonalVaultKeyVersion,
  key: vaultKey,
);
