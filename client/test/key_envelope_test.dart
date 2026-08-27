import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/key_envelope.dart';

void main() {
  final algorithm = DartXchacha20.poly1305Aead(
    random: _SequenceRandom(List<int>.generate(24, (index) => 0xc0 + index)),
  );
  final cipher = KeyEnvelopeCipher(algorithm: algorithm);
  final wrappingKey = SecretKeyData(
    List<int>.generate(32, (index) => 0x20 + index),
  );
  final fileKey = SecretKeyData(
    List<int>.generate(32, (index) => 0x60 + index),
  );
  final scopeId = Uint8List.fromList(List<int>.generate(16, (index) => index));
  final subjectId = Uint8List.fromList(
    List<int>.generate(16, (index) => 0x10 + index),
  );

  test('key envelope round-trips with stable versioned encoding', () async {
    final envelope = await cipher.wrapKey(
      wrappingKey: wrappingKey,
      keyToWrap: fileKey,
      purpose: KeyEnvelopePurpose.fileKey,
      keyVersion: 3,
      scopeId: scopeId,
      subjectId: subjectId,
    );
    final encoded = envelope.encode();
    expect(encoded.length, 83);
    expect(
      _hex(encoded),
      '4842584b00010100000003000000c0000000c1000000c2000000c3000000c4000000c5f5d3917e42ed9a7539f46cc0539baf976e56e4f6df6dcba2ba0f16ddffea528457a0af6ddb0f56acbe63935888c24a3f',
    );

    final unwrapped = await cipher.unwrapKey(
      wrappingKey: wrappingKey,
      envelope: KeyEnvelope.decode(encoded),
      scopeId: scopeId,
      subjectId: subjectId,
    );
    expect(await unwrapped.extractBytes(), await fileKey.extractBytes());
  });

  test('scope and subject IDs are authenticated', () async {
    final envelope = await cipher.wrapKey(
      wrappingKey: wrappingKey,
      keyToWrap: fileKey,
      purpose: KeyEnvelopePurpose.fileKey,
      keyVersion: 1,
      scopeId: scopeId,
      subjectId: subjectId,
    );
    final otherSubject = Uint8List.fromList(subjectId)..[0] ^= 1;
    await expectLater(
      cipher.unwrapKey(
        wrappingKey: wrappingKey,
        envelope: envelope,
        scopeId: scopeId,
        subjectId: otherSubject,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('tampered envelope is rejected', () async {
    final envelope = await cipher.wrapKey(
      wrappingKey: wrappingKey,
      keyToWrap: fileKey,
      purpose: KeyEnvelopePurpose.fileKey,
      keyVersion: 1,
      scopeId: scopeId,
      subjectId: subjectId,
    );
    final encoded = envelope.encode()..[40] ^= 1;
    await expectLater(
      cipher.unwrapKey(
        wrappingKey: wrappingKey,
        envelope: KeyEnvelope.decode(encoded),
        scopeId: scopeId,
        subjectId: subjectId,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

final class _SequenceRandom implements Random {
  _SequenceRandom(this._values);

  final List<int> _values;
  var _index = 0;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 26) / (1 << 26);

  @override
  int nextInt(int max) {
    if (max <= 0) throw ArgumentError.value(max, 'max');
    final value = _values[_index % _values.length];
    _index++;
    return value % max;
  }
}
