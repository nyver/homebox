import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_provisioning.dart';

void main() {
  final keyExchange = X25519();
  final vaultId = Uint8List.fromList(
    List<int>.generate(16, (index) => 0x10 + index),
  );
  final deviceId = Uint8List.fromList(
    List<int>.generate(16, (index) => 0x30 + index),
  );

  test('trusted device provisions a vault key to one recipient', () async {
    final recipient = await keyExchange.newKeyPair();
    final recipientPublicKey = await recipient.extractPublicKey();
    final vaultKeyBytes = Uint8List.fromList(
      List<int>.generate(32, (index) => 0x60 + index),
    );
    final vaultKey = SecretKeyData(vaultKeyBytes);
    final cipher = DeviceProvisioningCipher();

    final envelope = await cipher.create(
      vaultKey: vaultKey,
      keyVersion: 7,
      vaultId: vaultId,
      recipientDeviceId: deviceId,
      recipientPublicKey: recipientPublicKey,
    );
    final encoded = envelope.encode();
    expect(encoded.length, DeviceProvisioningEnvelope.encodedLength);
    expect(_contains(encoded, vaultKeyBytes), isFalse);

    final opened = await cipher.open(
      envelope: DeviceProvisioningEnvelope.decode(encoded),
      recipientKeyPair: recipient,
      vaultId: vaultId,
      recipientDeviceId: deviceId,
    );
    expect(await opened.extractBytes(), vaultKeyBytes);

    opened.destroy();
    vaultKey.destroy();
    recipient.destroy();
  });

  test('a different recipient cannot open the provisioning envelope', () async {
    final recipient = await keyExchange.newKeyPair();
    final otherRecipient = await keyExchange.newKeyPair();
    final cipher = DeviceProvisioningCipher();
    final vaultKey = SecretKeyData(List<int>.filled(32, 9));
    final envelope = await cipher.create(
      vaultKey: vaultKey,
      keyVersion: 1,
      vaultId: vaultId,
      recipientDeviceId: deviceId,
      recipientPublicKey: await recipient.extractPublicKey(),
    );

    await expectLater(
      cipher.open(
        envelope: envelope,
        recipientKeyPair: otherRecipient,
        vaultId: vaultId,
        recipientDeviceId: deviceId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    vaultKey.destroy();
    recipient.destroy();
    otherRecipient.destroy();
  });

  test('recipient device ID is authenticated', () async {
    final recipient = await keyExchange.newKeyPair();
    final cipher = DeviceProvisioningCipher();
    final vaultKey = SecretKeyData(List<int>.filled(32, 11));
    final envelope = await cipher.create(
      vaultKey: vaultKey,
      keyVersion: 2,
      vaultId: vaultId,
      recipientDeviceId: deviceId,
      recipientPublicKey: await recipient.extractPublicKey(),
    );
    final otherDeviceId = Uint8List.fromList(deviceId)..[0] ^= 1;

    await expectLater(
      cipher.open(
        envelope: envelope,
        recipientKeyPair: recipient,
        vaultId: vaultId,
        recipientDeviceId: otherDeviceId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    vaultKey.destroy();
    recipient.destroy();
  });

  test('tampering with a provisioning envelope is detected', () async {
    final recipient = await keyExchange.newKeyPair();
    final cipher = DeviceProvisioningCipher();
    final vaultKey = SecretKeyData(List<int>.filled(32, 13));
    final envelope = await cipher.create(
      vaultKey: vaultKey,
      keyVersion: 3,
      vaultId: vaultId,
      recipientDeviceId: deviceId,
      recipientPublicKey: await recipient.extractPublicKey(),
    );
    final tampered = envelope.encode()..[100] ^= 1;

    await expectLater(
      cipher.open(
        envelope: DeviceProvisioningEnvelope.decode(tampered),
        recipientKeyPair: recipient,
        vaultId: vaultId,
        recipientDeviceId: deviceId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    vaultKey.destroy();
    recipient.destroy();
  });

  test('low-order X25519 public keys are rejected', () async {
    final cipher = DeviceProvisioningCipher();
    final vaultKey = SecretKeyData(List<int>.filled(32, 15));

    await expectLater(
      cipher.create(
        vaultKey: vaultKey,
        keyVersion: 1,
        vaultId: vaultId,
        recipientDeviceId: deviceId,
        recipientPublicKey: SimplePublicKey(
          Uint8List(32),
          type: KeyPairType.x25519,
        ),
      ),
      throwsFormatException,
    );
    vaultKey.destroy();
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var index = 0; index <= haystack.length - needle.length; index++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[index + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
