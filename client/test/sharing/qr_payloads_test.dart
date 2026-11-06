import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/account_identity.dart';
import 'package:homebox_client/features/sharing/family_invite.dart';

const _accountId = '0f8fad5b-d9cb-469f-a165-70867728950e';
final _fingerprint = List.filled(32, 'AB').join(':');

void main() {
  test('a family invite round-trips and only matches its own fingerprint', () {
    final code = FamilyInvite(
      accountId: _accountId,
      fingerprint: _fingerprint,
    ).encode();

    final parsed = FamilyInvite.tryParse(code)!;
    expect(parsed.accountId, _accountId);
    expect(fingerprintsMatch(parsed.fingerprint, _fingerprint), isTrue);
    // Grouping and case do not matter; any other value does.
    expect(fingerprintsMatch(parsed.fingerprint, 'ab' * 32), isTrue);
    expect(fingerprintsMatch(parsed.fingerprint, '${'ab' * 31}ac'), isFalse);
  });

  test('anything that is not a valid family invite is rejected', () {
    for (final raw in [
      'https://example.com',
      'homebox://family?v=2&account=$_accountId&fp=${'ab' * 32}',
      'homebox://family?v=1&account=not-a-uuid&fp=${'ab' * 32}',
      'homebox://family?v=1&account=$_accountId&fp=abcd',
      'homebox://family?v=1&account=$_accountId',
    ]) {
      expect(FamilyInvite.tryParse(raw), isNull, reason: raw);
    }
  });

  test('a device pairing payload parses back and matches its device', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final payload = devicePairingPayload(
      deviceId: _accountId,
      keyVersion: 1,
      publicKey: key,
    );

    final record = DevicePairingRecord.tryParse(payload)!;
    expect(record.deviceId, _accountId);
    expect(record.keyVersion, 1);
    expect(
      record.matches(deviceId: _accountId.toUpperCase(), devicePublicKey: key),
      isTrue,
    );
    final otherKey = Uint8List.fromList(key)..[0] = 99;
    expect(
      record.matches(deviceId: _accountId, devicePublicKey: otherKey),
      isFalse,
    );
    expect(DevicePairingRecord.tryParse('homebox://family?v=1'), isNull);
    expect(
      DevicePairingRecord.tryParse(
        'homebox://pair-device?v=1&id=$_accountId&kv=1&key=short',
      ),
      isNull,
    );
  });
}
