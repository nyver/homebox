import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/account_identity.dart';

void main() {
  const accountId = '11111111-1111-1111-1111-111111111111';
  const deviceId = '22222222-2222-2222-2222-222222222222';

  test('Vault Key deterministically derives one account identity', () async {
    final vaultKey = SecretKeyData(List<int>.generate(32, (i) => i));
    final first = await AccountIdentity.derive(
      vaultKey: vaultKey,
      accountId: accountId,
    );
    final second = await AccountIdentity.derive(
      vaultKey: vaultKey,
      accountId: accountId,
    );
    expect(first.publicKey.bytes, second.publicKey.bytes);
    first.destroy();
    second.destroy();
    vaultKey.destroy();
  });

  test(
    'certificate binds account, device, key version, and X25519 key',
    () async {
      final vaultKey = SecretKeyData(List<int>.filled(32, 7));
      final identity = await AccountIdentity.derive(
        vaultKey: vaultKey,
        accountId: accountId,
      );
      final deviceKey = Uint8List.fromList(
        List<int>.generate(32, (i) => i + 1),
      );
      final certificate = await identity.certifyDevice(
        accountId: accountId,
        deviceId: deviceId,
        deviceKeyVersion: 1,
        devicePublicKey: deviceKey,
      );
      expect(
        await identity.verifyDevice(
          certificate: certificate,
          accountId: accountId,
          deviceId: deviceId,
          devicePublicKey: deviceKey,
        ),
        isTrue,
      );
      final tampered = Uint8List.fromList(deviceKey)..[0] ^= 1;
      expect(
        await identity.verifyDevice(
          certificate: certificate,
          accountId: accountId,
          deviceId: deviceId,
          devicePublicKey: tampered,
        ),
        isFalse,
      );
      identity.destroy();
      vaultKey.destroy();
    },
  );

  test('pairing presentation is stable and QR-ready', () async {
    final publicKey = List<int>.generate(32, (index) => index);
    final fingerprint = await devicePublicKeyFingerprint(publicKey);
    expect(fingerprint.split(':'), hasLength(32));
    expect(
      devicePairingPayload(
        deviceId: deviceId,
        keyVersion: 1,
        publicKey: publicKey,
      ),
      startsWith('homebox://pair-device?v=1&id=$deviceId&kv=1&key='),
    );
  });
}
