import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/opaque_id.dart';

void main() {
  test('generateUuidV4 produces distinct, well-formed v4 UUIDs', () {
    final pattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    final seen = <String>{};
    for (var i = 0; i < 100; i++) {
      final uuid = generateUuidV4();
      expect(pattern.hasMatch(uuid), isTrue, reason: 'not a v4 UUID: $uuid');
      expect(seen.add(uuid), isTrue, reason: 'duplicate UUID generated: $uuid');
    }
  });

  test('uuidStringToBytes and bytesToUuidString round-trip', () {
    final uuid = generateUuidV4();
    final bytes = uuidStringToBytes(uuid);
    expect(bytes.length, 16);
    expect(bytesToUuidString(bytes), uuid);
  });

  test('uuidStringToBytes accepts a UUID without dashes', () {
    const withDashes = '0f3a85b1-c370-ef0e-b221-9c6c2ea078d2';
    const withoutDashes = '0f3a85b1c370ef0eb2219c6c2ea078d2';
    expect(uuidStringToBytes(withoutDashes), uuidStringToBytes(withDashes));
  });

  test('uuidStringToBytes rejects malformed input', () {
    expect(() => uuidStringToBytes('not-a-uuid'), throwsFormatException);
    expect(() => uuidStringToBytes('0f3a85b1-c370-ef0e-b221-9c6c2ea078d2ff'), throwsFormatException);
  });

  test('bytesToUuidString rejects the wrong length', () {
    expect(() => bytesToUuidString(Uint8List(15)), throwsArgumentError);
  });
}
