import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/portable_name.dart';

void main() {
  test('normalizes names to NFC and preserves display case', () {
    expect(PortableName.normalizeAndValidate('Cafe\u0301.TXT'), 'Café.TXT');
  });

  test('comparison key is case insensitive', () {
    expect(
      PortableName.comparisonKey('Family Photo.jpg'),
      PortableName.comparisonKey('family photo.JPG'),
    );
  });

  test('rejects Windows reserved and path-like names', () {
    for (final name in [
      '.',
      '..',
      'CON',
      'con.txt',
      'LPT9.log',
      'bad/name',
      'bad\\name',
      'trailing.',
    ]) {
      expect(
        () => PortableName.normalizeAndValidate(name),
        throwsA(isA<FormatException>()),
        reason: name,
      );
    }
  });
}
