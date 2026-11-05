import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/portable_name.dart';
import 'package:homebox_client/features/sync/conflict_naming.dart';

void main() {
  final at = DateTime.utc(2026, 11, 5, 14, 3, 22);

  test('follows the spec format and keeps the extension', () {
    expect(
      conflictCopyName('report.docx', deviceName: 'LAPTOP', detectedAt: at),
      'report (conflict - LAPTOP - 2026-11-05 14-03-22 UTC).docx',
    );
  });

  test('uses UTC regardless of the given time zone', () {
    expect(
      conflictCopyName('a.txt', deviceName: 'pc', detectedAt: at.toLocal()),
      'a (conflict - pc - 2026-11-05 14-03-22 UTC).txt',
    );
  });

  test(
    'treats hidden files and long or spaced suffixes as part of the name',
    () {
      expect(
        conflictCopyName('.gitignore', deviceName: 'pc', detectedAt: at),
        '.gitignore (conflict - pc - 2026-11-05 14-03-22 UTC)',
      );
      expect(
        conflictCopyName(
          'notes.from the meeting',
          deviceName: 'pc',
          detectedAt: at,
        ),
        'notes.from the meeting (conflict - pc - 2026-11-05 14-03-22 UTC)',
      );
      expect(
        conflictCopyName('archive', deviceName: 'pc', detectedAt: at),
        'archive (conflict - pc - 2026-11-05 14-03-22 UTC)',
      );
    },
  );

  test('adds a short unique suffix when asked', () {
    expect(
      conflictCopyName(
        'a.txt',
        deviceName: 'pc',
        detectedAt: at,
        uniqueSuffix: '1a2b3c4d',
      ),
      'a (conflict - pc - 2026-11-05 14-03-22 UTC - 1a2b3c4d).txt',
    );
  });

  test('sanitizes device names that are not portable', () {
    expect(sanitizeConflictDeviceLabel('my:pc/(home)'), 'my-pc--home-');
    expect(sanitizeConflictDeviceLabel('  \t '), 'device');
    expect(sanitizeConflictDeviceLabel('pc...'), 'pc');
    expect(sanitizeConflictDeviceLabel('x' * 80).length, 32);
  });

  test('stays a valid portable name within 255 code units', () {
    final name = conflictCopyName(
      '${'\u{1F600}' * 130}.txt',
      deviceName: 'a-very-long-device-name-that-goes-on-and-on',
      detectedAt: at,
    );
    expect(name.length, lessThanOrEqualTo(255));
    expect(PortableName.normalizeAndValidate(name), name);
    expect(name, endsWith(' UTC).txt'));
  });

  test('details name the original file, the device and the reason', () {
    expect(
      conflictCopyDetails(
        originalName: 'note.txt',
        deviceName: 'pc',
        detectedAt: at,
        reason: 'both changed.',
      ),
      'Conflict copy of "note.txt" kept by pc on 2026-11-05 14:03 UTC: both changed.',
    );
  });
}
