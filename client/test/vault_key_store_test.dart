import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/opaque_id.dart';
import 'package:homebox_client/core/e2ee/recovery.dart';
import 'package:homebox_client/core/e2ee/recovery_bundle.dart';
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

  test(
    'a provisioned Vault Key is persisted without recovery material',
    () async {
      final store = VaultKeyStore(MemoryVaultKeyStorage());
      final provisionedKey = SecretKeyData(
        List<int>.generate(32, (index) => index),
      );

      await store.saveProvisionedVaultKey(provisionedKey);

      expect(await store.exists(), isTrue);
      expect(
        await _bytesOf((await store.loadVaultKey())!),
        await _bytesOf(provisionedKey),
      );
      expect(await store.loadUserMasterKey(), isNull);
      expect(await store.loadRecoveryPackage(), isNull);
      provisionedKey.destroy();
    },
  );

  test('a Recovery Secret alone restores the exact vault on a clean device', () async {
    final originStore = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();
    final recoverySecret = await originStore.createVault(userId: userId);
    final originalVaultKey = await _bytesOf((await originStore.loadVaultKey())!);
    final originalUmk = await _bytesOf((await originStore.loadUserMasterKey())!);
    final bundle = (await originStore.sealRecoveryBundle(userId: userId))!;
    // The server only ever relays the encoded bytes.
    final relayed = RecoveryBundle.decode(bundle.encode());

    final cleanStore = VaultKeyStore(MemoryVaultKeyStorage());
    await cleanStore.restoreVaultFromRecovery(
      userId: userId,
      recoverySecret: recoverySecret,
      bundle: relayed,
    );

    expect(await cleanStore.exists(), isTrue);
    expect(await _bytesOf((await cleanStore.loadVaultKey())!), originalVaultKey);
    expect(await _bytesOf((await cleanStore.loadUserMasterKey())!), originalUmk);
    // A recovered device can in turn seal the same recovery material.
    expect(await cleanStore.sealRecoveryBundle(userId: userId), isNotNull);
    recoverySecret.destroy();
  });

  test('a wrong Recovery Secret or account leaves the clean device untouched', () async {
    final originStore = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();
    final recoverySecret = await originStore.createVault(userId: userId);
    final bundle = (await originStore.sealRecoveryBundle(userId: userId))!;

    final wrongSecret = RecoverySecret.generate();
    final cleanStore = VaultKeyStore(MemoryVaultKeyStorage());
    await expectLater(
      cleanStore.restoreVaultFromRecovery(
        userId: userId,
        recoverySecret: wrongSecret,
        bundle: bundle,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await expectLater(
      cleanStore.restoreVaultFromRecovery(
        userId: generateUuidV4(),
        recoverySecret: recoverySecret,
        bundle: bundle,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    expect(await cleanStore.exists(), isFalse);
    expect(await cleanStore.loadUserMasterKey(), isNull);
    wrongSecret.destroy();
    recoverySecret.destroy();
  });

  test('restoring refuses to replace an existing local vault', () async {
    final store = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();
    final recoverySecret = await store.createVault(userId: userId);
    final bundle = (await store.sealRecoveryBundle(userId: userId))!;

    await expectLater(
      store.restoreVaultFromRecovery(
        userId: userId,
        recoverySecret: recoverySecret,
        bundle: bundle,
      ),
      throwsStateError,
    );
    recoverySecret.destroy();
  });

  test('a provisioned device can issue a new Recovery Secret for the same Vault Key', () async {
    final userId = generateUuidV4();
    final provisionedStore = VaultKeyStore(MemoryVaultKeyStorage());
    final vaultKey = SecretKeyData(List<int>.generate(32, (index) => 255 - index));
    await provisionedStore.saveProvisionedVaultKey(vaultKey);
    // No User Master Key on a provisioned device, so nothing to seal yet.
    expect(await provisionedStore.sealRecoveryBundle(userId: userId), isNull);

    final prepared = await provisionedStore.prepareNewRecoverySecret(
      userId: userId,
    );
    // Nothing is persisted until the caller confirms the server accepted it.
    expect(await provisionedStore.loadRecoveryPackage(), isNull);
    await provisionedStore.savePreparedRecovery(prepared);
    expect(await provisionedStore.loadRecoveryPackage(), isNotNull);

    final cleanStore = VaultKeyStore(MemoryVaultKeyStorage());
    await cleanStore.restoreVaultFromRecovery(
      userId: userId,
      recoverySecret: prepared.recoverySecret,
      bundle: prepared.bundle,
    );
    expect(
      await _bytesOf((await cleanStore.loadVaultKey())!),
      await _bytesOf(vaultKey),
    );
    prepared.destroy();
    vaultKey.destroy();
  });

  test('a recovery bundle rejects corrupted encodings', () async {
    final store = VaultKeyStore(MemoryVaultKeyStorage());
    final userId = generateUuidV4();
    final recoverySecret = await store.createVault(userId: userId);
    final encoded = (await store.sealRecoveryBundle(userId: userId))!.encode();
    recoverySecret.destroy();

    expect(RecoveryBundle.encodedLength, encoded.length);
    final badMagic = Uint8List.fromList(encoded)..[0] ^= 0xff;
    expect(() => RecoveryBundle.decode(badMagic), throwsFormatException);
    expect(
      () => RecoveryBundle.decode(encoded.sublist(0, encoded.length - 1)),
      throwsFormatException,
    );
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
