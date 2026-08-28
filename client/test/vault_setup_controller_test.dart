import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/opaque_id.dart';
import 'package:homebox_client/core/e2ee/recovery.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/features/vault/vault_setup_controller.dart';

import 'support/memory_vault_key_storage.dart';

void main() {
  test('createVault transitions locked -> creating -> ready and returns a valid Recovery Secret', () async {
    final storage = MemoryVaultKeyStorage();
    final controller = VaultSetupController(VaultKeyStore(storage));
    final userId = generateUuidV4();

    await controller.initialize();
    expect(controller.status, VaultSetupStatus.locked);

    final secretText = await controller.createVault(userId);
    expect(controller.status, VaultSetupStatus.ready);
    expect(secretText, isNotNull);
    final parsed = RecoverySecret.parse(secretText!);
    parsed.destroy();

    final reloaded = VaultSetupController(VaultKeyStore(storage));
    await reloaded.initialize();
    expect(reloaded.status, VaultSetupStatus.ready);

    controller.dispose();
    reloaded.dispose();
  });

  test('a second createVault call is a no-op once the vault is ready', () async {
    final storage = MemoryVaultKeyStorage();
    final controller = VaultSetupController(VaultKeyStore(storage));
    final userId = generateUuidV4();

    final first = await controller.createVault(userId);
    expect(first, isNotNull);
    final second = await controller.createVault(userId);
    expect(second, isNull);
    expect(controller.status, VaultSetupStatus.ready);

    controller.dispose();
  });
}
