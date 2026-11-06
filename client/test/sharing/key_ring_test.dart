import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/account_identity.dart';
import 'package:homebox_client/core/e2ee/key_ring.dart';

const _owner = '11111111-1111-4111-8111-111111111111';
const _folder = '22222222-2222-4222-8222-222222222222';
const _otherFolder = '33333333-3333-4333-8333-333333333333';
const _recipient = '44444444-4444-4444-8444-444444444444';
const _device = '55555555-5555-4555-8555-555555555555';

Future<SecretKey> _randomKey() async => SecretKeyData.random(length: 32);

void main() {
  test(
    'a folder key wrapped for its owner opens only in its own context',
    () async {
      final vaultKey = await _randomKey();
      final folderKey = await _randomKey();
      final envelope = await wrapFolderKeyForOwner(
        vaultKey: vaultKey,
        folderKey: folderKey,
        folderId: _folder,
        ownerUserId: _owner,
        version: 2,
      );
      final opened = await unwrapFolderKeyForOwner(
        vaultKey: vaultKey,
        folderId: _folder,
        ownerUserId: _owner,
        envelope: envelope,
        expectedVersion: 2,
      );
      expect(await opened.extractBytes(), await folderKey.extractBytes());

      // The server cannot present it as another folder's or version's key.
      await expectLater(
        unwrapFolderKeyForOwner(
          vaultKey: vaultKey,
          folderId: _otherFolder,
          ownerUserId: _owner,
          envelope: envelope,
          expectedVersion: 2,
        ),
        throwsA(anything),
      );
      await expectLater(
        unwrapFolderKeyForOwner(
          vaultKey: vaultKey,
          folderId: _folder,
          ownerUserId: _owner,
          envelope: envelope,
          expectedVersion: 1,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'the owner key ring resolves the vault and every folder key version',
    () async {
      final vaultKey = await _randomKey();
      final v1 = await _randomKey();
      final v2 = await _randomKey();
      Future<Uint8List> wrap(SecretKey key, int version) =>
          wrapFolderKeyForOwner(
            vaultKey: vaultKey,
            folderKey: key,
            folderId: _folder,
            ownerUserId: _owner,
            version: version,
          );
      final ring = OwnerKeyRing(
        userId: _owner,
        vaultKey: vaultKey,
        vaultKeyVersion: 1,
        wrappedFolderKeys: {
          _folder: {1: await wrap(v1, 1), 2: await wrap(v2, 2)},
        },
      );
      addTearDown(ring.dispose);

      expect((await ring.key(_owner, 1)).key, same(vaultKey));
      expect(
        await (await ring.key(_folder, 1)).key.extractBytes(),
        await v1.extractBytes(),
      );
      final current = await ring.current(_folder);
      expect(current.version, 2);
      expect(await current.key.extractBytes(), await v2.extractBytes());
      expect(ring.latestVersion(_folder), 2);
      expect(ring.isKeyedFolder(_otherFolder), isFalse);
      await expectLater(
        ring.key(_otherFolder, 1),
        throwsA(isA<MissingScopeKeyException>()),
      );
      await expectLater(
        ring.key(_owner, 2),
        throwsA(isA<MissingScopeKeyException>()),
      );
    },
  );

  test(
    'a share envelope signature binds folder, accounts, device, and bytes',
    () async {
      final identity = await AccountIdentity.derive(
        vaultKey: await _randomKey(),
        accountId: _owner,
      );
      final envelope = Uint8List.fromList(List.generate(64, (i) => i));
      final signature = await identity.signFamilyShareEnvelope(
        folderId: _folder,
        ownerAccountId: _owner,
        recipientAccountId: _recipient,
        recipientDeviceId: _device,
        keyVersion: 3,
        envelope: envelope,
      );
      Future<bool> verify({
        String folderId = _folder,
        String deviceId = _device,
        int keyVersion = 3,
        List<int>? bytes,
      }) => AccountIdentity.verifyFamilyShareEnvelope(
        ownerIdentityPublicKey: identity.publicKey.bytes,
        signature: signature,
        folderId: folderId,
        ownerAccountId: _owner,
        recipientAccountId: _recipient,
        recipientDeviceId: deviceId,
        keyVersion: keyVersion,
        envelope: bytes ?? envelope,
      );

      expect(await verify(), isTrue);
      expect(await verify(folderId: _otherFolder), isFalse);
      expect(await verify(deviceId: _recipient), isFalse);
      expect(await verify(keyVersion: 4), isFalse);
      expect(await verify(bytes: [...envelope]..[0] ^= 1), isFalse);
    },
  );

  test(
    'a device certificate verifies only against its own account identity',
    () async {
      final member = await AccountIdentity.derive(
        vaultKey: await _randomKey(),
        accountId: _recipient,
      );
      final other = await AccountIdentity.derive(
        vaultKey: await _randomKey(),
        accountId: _recipient,
      );
      final devicePublicKey = List<int>.filled(32, 7);
      final certificate = await member.certifyDevice(
        accountId: _recipient,
        deviceId: _device,
        deviceKeyVersion: 1,
        devicePublicKey: devicePublicKey,
      );
      Future<bool> verify(List<int> identity, List<int> deviceKey) =>
          verifyDeviceCertificate(
            identityPublicKey: identity,
            certificate: certificate,
            accountId: _recipient,
            deviceId: _device,
            devicePublicKey: deviceKey,
          );
      expect(await verify(member.publicKey.bytes, devicePublicKey), isTrue);
      expect(await verify(other.publicKey.bytes, devicePublicKey), isFalse);
      expect(
        await verify(member.publicKey.bytes, List<int>.filled(32, 8)),
        isFalse,
      );
    },
  );
}
