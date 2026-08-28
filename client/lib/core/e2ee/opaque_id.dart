import 'dart:math' as math;
import 'dart:typed_data';

/// Generates a random version-4 UUID string, used for every client-generated
/// opaque identifier (node IDs, file version IDs, blob IDs, operation IDs —
/// spec §14: "Client-generated ID обязателен для объектов, которые могут
/// создаваться offline").
String generateUuidV4([math.Random? random]) {
  final rng = random ?? math.Random.secure();
  final bytes = Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  return _bytesToUuidString(bytes);
}

/// Converts a UUID string (with or without dashes) to its canonical 16 raw
/// bytes — the same representation Go's `uuid.UUID` produces for the
/// identical string, per RFC 4122. Used as the `scopeId`/`subjectId` inputs
/// to key-envelope AAD (ADR-011) and to bind file/node IDs into AEAD
/// authenticated data (ADR-010). This is a plain, unambiguous byte layout
/// shared by any correct UUID implementation, so no coordination with the
/// server is required beyond both sides agreeing on the UUID string itself.
Uint8List uuidStringToBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw FormatException('Invalid UUID: $uuid');
  }
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final byteHex = hex.substring(i * 2, i * 2 + 2);
    final value = int.tryParse(byteHex, radix: 16);
    if (value == null) throw FormatException('Invalid UUID: $uuid');
    bytes[i] = value;
  }
  return bytes;
}

String bytesToUuidString(Uint8List bytes) {
  if (bytes.length != 16) {
    throw ArgumentError.value(bytes.length, 'bytes.length', 'UUID bytes must be 16 bytes long.');
  }
  return _bytesToUuidString(bytes);
}

String _bytesToUuidString(Uint8List bytes) {
  String hexRange(int start, int end) =>
      bytes.sublist(start, end).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hexRange(0, 4)}-${hexRange(4, 6)}-${hexRange(6, 8)}-${hexRange(8, 10)}-${hexRange(10, 16)}';
}
