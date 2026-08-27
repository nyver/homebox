import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/recovery.dart';

void main() {
  test('Recovery Secret has a versioned printable round-trip', () async {
    final secret = RecoverySecret.generate();
    final encoded = await secret.export();
    expect(encoded, startsWith(RecoverySecret.prefix));
    expect(encoded.length, RecoverySecret.prefix.length + 43);

    final parsed = RecoverySecret.parse(encoded);
    expect(await parsed.export(), encoded);
    parsed.destroy();
    secret.destroy();
  });

  test('recovery package restores the exact User Master Key', () async {
    final secret = RecoverySecret.generate();
    final masterKeyBytes = Uint8List.fromList(
      List<int>.generate(32, (index) => 0x30 + index),
    );
    final masterKey = SecretKeyData(masterKeyBytes);
    final userId = Uint8List.fromList(
      List<int>.generate(16, (index) => 0x10 + index),
    );
    final cipher = RecoveryPackageCipher();

    final package = await cipher.create(
      recoverySecret: secret,
      userMasterKey: masterKey,
      userId: userId,
    );
    final encoded = package.encode();
    expect(encoded.length, RecoveryPackage.encodedLength);
    expect(_contains(encoded, masterKeyBytes), isFalse);

    final restored = await cipher.restore(
      recoverySecret: secret,
      recoveryPackage: RecoveryPackage.decode(encoded),
      userId: userId,
    );
    expect(await restored.extractBytes(), masterKeyBytes);

    restored.destroy();
    masterKey.destroy();
    secret.destroy();
  });

  test('wrong Recovery Secret cannot restore the package', () async {
    final correctSecret = RecoverySecret.generate();
    final wrongSecret = RecoverySecret.generate();
    final userId = Uint8List(16);
    final cipher = RecoveryPackageCipher();
    final masterKey = SecretKeyData(List<int>.filled(32, 7));
    final package = await cipher.create(
      recoverySecret: correctSecret,
      userMasterKey: masterKey,
      userId: userId,
    );
    await expectLater(
      cipher.restore(
        recoverySecret: wrongSecret,
        recoveryPackage: package,
        userId: userId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    wrongSecret.destroy();
    correctSecret.destroy();
    masterKey.destroy();
  });

  test('recovery package is authenticated for one user ID', () async {
    final secret = RecoverySecret.generate();
    final userId = Uint8List(16);
    final cipher = RecoveryPackageCipher();
    final masterKey = SecretKeyData(List<int>.filled(32, 9));
    final package = await cipher.create(
      recoverySecret: secret,
      userMasterKey: masterKey,
      userId: userId,
    );
    final otherUserId = Uint8List.fromList(userId)..[0] = 1;
    await expectLater(
      cipher.restore(
        recoverySecret: secret,
        recoveryPackage: package,
        userId: otherUserId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    secret.destroy();
    masterKey.destroy();
  });

  test('tampered recovery package never yields key material', () async {
    final secret = RecoverySecret.generate();
    final userId = Uint8List(16);
    final masterKey = SecretKeyData(List<int>.filled(32, 11));
    final cipher = RecoveryPackageCipher();
    final package = await cipher.create(
      recoverySecret: secret,
      userMasterKey: masterKey,
      userId: userId,
    );
    final encoded = package.encode()..[70] ^= 1;
    await expectLater(
      cipher.restore(
        recoverySecret: secret,
        recoveryPackage: RecoveryPackage.decode(encoded),
        userId: userId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    secret.destroy();
    masterKey.destroy();
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
