import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';

import 'support/memory_device_private_key_storage.dart';

void main() {
  test('device identity persists in secure storage and reloads', () async {
    final storage = MemoryDevicePrivateKeyStorage();
    final identityStore = DeviceIdentityStore(storage);

    final created = await identityStore.loadOrCreate();
    final createdPublicKey = created.publicKey.bytes;
    expect(storage.values.keys, [homeBoxDevicePrivateKeyStorageKey]);
    expect(
      storage.values[homeBoxDevicePrivateKeyStorageKey],
      startsWith('HBXD1-'),
    );
    expect(created.toString(), isNot(contains(storage.values.values.single)));
    created.destroy();

    final loaded = await identityStore.load();
    expect(loaded, isNotNull);
    expect(loaded!.publicKey.bytes, createdPublicKey);
    loaded.destroy();
  });

  test('clearing a device identity removes its private key', () async {
    final storage = MemoryDevicePrivateKeyStorage();
    final identityStore = DeviceIdentityStore(storage);
    final identity = await identityStore.loadOrCreate();

    await identityStore.clear();
    expect(await identityStore.load(), isNull);
    identity.destroy();
  });

  test('corrupt secure storage never silently rotates identity', () async {
    final storage = MemoryDevicePrivateKeyStorage()
      ..values[homeBoxDevicePrivateKeyStorageKey] = 'HBXD1-invalid';
    final identityStore = DeviceIdentityStore(storage);

    await expectLater(identityStore.loadOrCreate(), throwsFormatException);
    expect(storage.values[homeBoxDevicePrivateKeyStorageKey], 'HBXD1-invalid');
  });
}
