import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/opaque_id.dart';
import 'package:homebox_client/core/e2ee/recovery.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';

import 'support/memory_vault_key_storage.dart';

Future<List<int>> _bytesOf(SecretKey key) => key.extractBytes();

void main() {
  test('createVault persists a usable Vault Key and User Master Key', () async {
    final store = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();

    expect(await store.exists(), isFalse);
    final recoverySecret = await store.createVault(userId: userId);
    expect(await store.exists(), isTrue);

    final vaultKey = await store.loadVaultKey();
    final userMasterKey = await store.loadUserMasterKey();
    expect(vaultKey, isNotNull);
    expect(userMasterKey, isNotNull);
    expect(await _bytesOf(vaultKey!), hasLength(32));
    expect(await _bytesOf(userMasterKey!), hasLength(32));
    expect(await _bytesOf(vaultKey), isNot(await _bytesOf(userMasterKey)));

    recoverySecret.destroy();
  });

  test('createVault refuses to overwrite an existing vault', () async {
    final store = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();
    final first = await store.createVault(userId: userId);
    first.destroy();

    expect(() => store.createVault(userId: userId), throwsStateError);
  });

  test('a Recovery Package created during setup restores the exact User Master Key elsewhere', () async {
    final originStorage = MemoryVaultKeyStorage();
    final originStore = VaultKeyStore(originStorage);
    final userId = generateUuidV4();
    final recoverySecret = await originStore.createVault(userId: userId);
    final originalUmkBytes = await _bytesOf((await originStore.loadUserMasterKey())!);
    final package = (await originStore.loadRecoveryPackage())!;

    // Simulate a clean device: a fresh store with no local vault yet.
    final cleanStore = VaultKeyStore(MemoryVaultKeyStorage());
    expect(await cleanStore.loadUserMasterKey(), isNull);
    await cleanStore.restoreUserMasterKeyFromRecovery(
      userId: userId,
      recoverySecret: recoverySecret,
      recoveryPackage: package,
    );
    final restoredUmkBytes = await _bytesOf((await cleanStore.loadUserMasterKey())!);
    expect(restoredUmkBytes, originalUmkBytes);
    // Recovery restores the UMK but never the Vault Key itself — that still
    // requires trusted-device provisioning.
    expect(await cleanStore.loadVaultKey(), isNull);

    recoverySecret.destroy();
  });

  test('restoring with the wrong Recovery Secret fails authentication', () async {
    final originStore = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();
    final recoverySecret = await originStore.createVault(userId: userId);
    final package = (await originStore.loadRecoveryPackage())!;
    recoverySecret.destroy();

    final wrongSecret = RecoverySecret.generate();
    final cleanStore = VaultKeyStore(MemoryVaultKeyStorage());
    await expectLater(
      cleanStore.restoreUserMasterKeyFromRecovery(userId: userId, recoverySecret: wrongSecret, recoveryPackage: package),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    wrongSecret.destroy();
  });

  test('clear removes every persisted secret', () async {
    final store = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();
    final recoverySecret = await store.createVault(userId: userId);
    recoverySecret.destroy();

    await store.clear();
    expect(await store.exists(), isFalse);
    expect(await store.loadUserMasterKey(), isNull);
    expect(await store.loadRecoveryPackage(), isNull);
  });
}
