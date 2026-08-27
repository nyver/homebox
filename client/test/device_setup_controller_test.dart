import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/features/device/device_setup_controller.dart';

import 'support/memory_device_private_key_storage.dart';

void main() {
  test(
    'preparing a Windows device produces a stable public fingerprint',
    () async {
      final storage = MemoryDevicePrivateKeyStorage();
      final controller = DeviceSetupController(DeviceIdentityStore(storage));

      await controller.initialize();
      expect(controller.status, DeviceSetupStatus.missing);

      await controller.prepareDevice();
      final fingerprint = controller.publicKeyFingerprint;
      expect(controller.status, DeviceSetupStatus.ready);
      expect(
        fingerprint,
        matches(RegExp(r'^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$')),
      );

      final reloaded = DeviceSetupController(DeviceIdentityStore(storage));
      await reloaded.initialize();
      expect(reloaded.status, DeviceSetupStatus.ready);
      expect(reloaded.publicKeyFingerprint, fingerprint);

      controller.dispose();
      reloaded.dispose();
    },
  );

  test('secure-storage failures are presented as a failed state', () async {
    final controller = DeviceSetupController(
      DeviceIdentityStore(MemoryDevicePrivateKeyStorage(failReads: true)),
    );

    await controller.initialize();
    expect(controller.status, DeviceSetupStatus.failed);
    expect(controller.publicKeyFingerprint, isNull);
    controller.dispose();
  });
}
