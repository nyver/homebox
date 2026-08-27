import 'package:unorm_dart/unorm_dart.dart' as unicode;

final class PortableName {
  PortableName._();

  static final RegExp _invalidCharacters = RegExp(r'[<>:"/\\|?*]');
  static final RegExp _reservedWindowsName = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
    caseSensitive: false,
  );

  static String normalizeAndValidate(String value) {
    final normalized = unicode.nfc(value);
    if (normalized.isEmpty) {
      throw const FormatException('A file name cannot be empty.');
    }
    if (normalized == '.' || normalized == '..') {
      throw const FormatException(
        'Relative path components are not file names.',
      );
    }
    if (normalized.length > 255) {
      throw const FormatException(
        'A file name cannot exceed 255 UTF-16 code units.',
      );
    }
    if (_invalidCharacters.hasMatch(normalized) ||
        normalized.runes.any((value) => value < 0x20)) {
      throw const FormatException(
        'The file name contains a non-portable character.',
      );
    }
    if (normalized.endsWith('.') || normalized.endsWith(' ')) {
      throw const FormatException(
        'A file name cannot end with a dot or space.',
      );
    }
    final baseName = normalized
        .split('.')
        .first
        .replaceFirst(RegExp(r'[ .]+$'), '');
    if (_reservedWindowsName.hasMatch(baseName)) {
      throw const FormatException('The file name is reserved by Windows.');
    }
    return normalized;
  }

  static String comparisonKey(String value) =>
      unicode.nfc(normalizeAndValidate(value).toUpperCase());
}
