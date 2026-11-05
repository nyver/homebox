import 'dart:io';

import '../../core/e2ee/portable_name.dart';

/// Longest device label embedded in a conflict-copy name.
const int _maxDeviceLabelLength = 32;

/// Longest suffix treated as a file extension; anything longer is part of
/// the base name (e.g. `notes.from the meeting`).
const int _maxExtensionLength = 16;

/// Builds the conflict-copy name from spec §21:
/// `<basename> (conflict - <device> - <UTC date>)<extension>`, plus
/// [uniqueSuffix] when that name is already taken. The result is always a
/// valid [PortableName]: the device label is sanitized, the timestamp avoids
/// characters Windows forbids, and the base name is shortened when needed to
/// stay within 255 UTF-16 code units.
String conflictCopyName(
  String fileName, {
  required String deviceName,
  required DateTime detectedAt,
  String? uniqueSuffix,
}) {
  final (base, extension) = _splitExtension(fileName);
  final utc = detectedAt.toUtc();
  final stamp =
      '${_four(utc.year)}-${_two(utc.month)}-${_two(utc.day)} '
      '${_two(utc.hour)}-${_two(utc.minute)}-${_two(utc.second)} UTC';
  final device = sanitizeConflictDeviceLabel(deviceName);
  final suffix = uniqueSuffix == null || uniqueSuffix.isEmpty
      ? ''
      : ' - ${sanitizeConflictDeviceLabel(uniqueSuffix)}';
  final marker = ' (conflict - $device - $stamp$suffix)';
  final budget = 255 - marker.length - extension.length;
  final shortenedBase = _truncateCodeUnits(base, budget < 1 ? 1 : budget);
  return PortableName.normalizeAndValidate('$shortenedBase$marker$extension');
}

/// The device label used in conflict-copy names: this computer's host name,
/// matching the device name registered with the server at login.
String localConflictDeviceName() {
  try {
    return sanitizeConflictDeviceLabel(Platform.localHostname);
  } catch (_) {
    return 'device';
  }
}

/// Replaces characters that are not portable in a file name, collapses
/// whitespace, and bounds the length, so any host name is safe to embed.
String sanitizeConflictDeviceLabel(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[<>:"/\\|?*()\x00-\x1f\x7f]'), '-')
      .trim();
  final bounded = _truncateCodeUnits(cleaned, _maxDeviceLabelLength).trim();
  final withoutTrailingDots = bounded.replaceFirst(RegExp(r'[ .]+$'), '');
  return withoutTrailingDots.isEmpty ? 'device' : withoutTrailingDots;
}

/// The encrypted `conflictDetails` text stored with an uploaded conflict
/// copy, visible on every device that can decrypt the vault.
String conflictCopyDetails({
  required String originalName,
  required String deviceName,
  required DateTime detectedAt,
  required String reason,
}) {
  final utc = detectedAt.toUtc();
  final when =
      '${_four(utc.year)}-${_two(utc.month)}-${_two(utc.day)} '
      '${_two(utc.hour)}:${_two(utc.minute)} UTC';
  final text =
      'Conflict copy of "$originalName" kept by '
      '${sanitizeConflictDeviceLabel(deviceName)} on $when: $reason';
  return _truncateCodeUnits(text, 1024);
}

(String, String) _splitExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  // A leading dot is a hidden-file name, not an extension (".gitignore").
  if (dot <= 0 || fileName.length - dot > _maxExtensionLength) {
    return (fileName, '');
  }
  final extension = fileName.substring(dot);
  if (extension.contains(' ')) return (fileName, '');
  return (fileName.substring(0, dot), extension);
}

/// Shortens [value] to at most [maxLength] UTF-16 code units without
/// splitting a surrogate pair.
String _truncateCodeUnits(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  var end = maxLength;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return value.substring(0, end);
}

String _two(int value) => value.toString().padLeft(2, '0');
String _four(int value) => value.toString().padLeft(4, '0');
