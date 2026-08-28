import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/family_share_key.dart';

void main() {
  final keyExchange = X25519();
  final folderId = _id(0x10);
  final ownerUserId = _id(0x30);
  final recipientUserId = _id(0x50);
  final recipientDeviceId = _id(0x70);

  test('recipient opens only its Family Vault folder key envelope', () async {
    final recipient = await keyExchange.newKeyPair();
    final folderKeyBytes = Uint8List.fromList(
      List<int>.generate(32, (index) => 0x90 + index),
    );
    final folderKey = SecretKeyData(folderKeyBytes);
    final cipher = FamilyShareKeyCipher();

    final envelope = await cipher.create(
      folderKey: folderKey,
      keyVersion: 4,
      folderId: folderId,
      ownerUserId: ownerUserId,
      recipientUserId: recipientUserId,
      recipientDeviceId: recipientDeviceId,
      recipientPublicKey: await recipient.extractPublicKey(),
    );
    final encoded = envelope.encode();
    expect(encoded.length, FamilyShareKeyEnvelope.encodedLength);
    expect(_contains(encoded, folderKeyBytes), isFalse);

    final opened = await cipher.open(
      envelope: FamilyShareKeyEnvelope.decode(encoded),
      recipientKeyPair: recipient,
      folderId: folderId,
      ownerUserId: ownerUserId,
      recipientUserId: recipientUserId,
      recipientDeviceId: recipientDeviceId,
    );
    expect(await opened.extractBytes(), folderKeyBytes);

    opened.destroy();
    folderKey.destroy();
    recipient.destroy();
  });

  test('share context and recipient substitutions are rejected', () async {
    final recipient = await keyExchange.newKeyPair();
    final otherRecipient = await keyExchange.newKeyPair();
    final folderKey = SecretKeyData(List<int>.filled(32, 4));
    final cipher = FamilyShareKeyCipher();
    final envelope = await cipher.create(
      folderKey: folderKey,
      keyVersion: 1,
      folderId: folderId,
      ownerUserId: ownerUserId,
      recipientUserId: recipientUserId,
      recipientDeviceId: recipientDeviceId,
      recipientPublicKey: await recipient.extractPublicKey(),
    );

    await expectLater(
      cipher.open(
        envelope: envelope,
        recipientKeyPair: recipient,
        folderId: _different(folderId),
        ownerUserId: ownerUserId,
        recipientUserId: recipientUserId,
        recipientDeviceId: recipientDeviceId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await expectLater(
      cipher.open(
        envelope: envelope,
        recipientKeyPair: recipient,
        folderId: folderId,
        ownerUserId: _different(ownerUserId),
        recipientUserId: recipientUserId,
        recipientDeviceId: recipientDeviceId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await expectLater(
      cipher.open(
        envelope: envelope,
        recipientKeyPair: recipient,
        folderId: folderId,
        ownerUserId: ownerUserId,
        recipientUserId: _different(recipientUserId),
        recipientDeviceId: recipientDeviceId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await expectLater(
      cipher.open(
        envelope: envelope,
        recipientKeyPair: recipient,
        folderId: folderId,
        ownerUserId: ownerUserId,
        recipientUserId: recipientUserId,
        recipientDeviceId: _different(recipientDeviceId),
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await expectLater(
      cipher.open(
        envelope: envelope,
        recipientKeyPair: otherRecipient,
        folderId: folderId,
        ownerUserId: ownerUserId,
        recipientUserId: recipientUserId,
        recipientDeviceId: recipientDeviceId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    folderKey.destroy();
    recipient.destroy();
    otherRecipient.destroy();
  });

  test('a low-order recipient public key is rejected', () async {
    final cipher = FamilyShareKeyCipher();
    final folderKey = SecretKeyData(List<int>.filled(32, 8));

    await expectLater(
      cipher.create(
        folderKey: folderKey,
        keyVersion: 1,
        folderId: folderId,
        ownerUserId: ownerUserId,
        recipientUserId: recipientUserId,
        recipientDeviceId: recipientDeviceId,
        recipientPublicKey: SimplePublicKey(
          Uint8List(32),
          type: KeyPairType.x25519,
        ),
      ),
      throwsFormatException,
    );
    folderKey.destroy();
  });
}

Uint8List _id(int start) =>
    Uint8List.fromList(List<int>.generate(16, (index) => start + index));

Uint8List _different(Uint8List value) => Uint8List.fromList(value)..[0] ^= 1;

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
