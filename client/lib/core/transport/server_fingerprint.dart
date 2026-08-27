import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

/// Extracts the raw P-256 public key point from an X.509 certificate
/// encoded in DER and returns its SHA-256 fingerprint as lowercase hex,
/// matching the server's `serveridentity.Identity.Fingerprint()` /
/// `FingerprintFromPublicKey` (ADR-008/ADR-009).
///
/// HomeBox certificates carry an ECDSA P-256 SubjectPublicKeyInfo, whose
/// DER encoding is fixed by RFC 5480: a constant 26-byte prefix
/// (`3059301306072a8648ce3d020106082a8648ce3d030107034200`) immediately
/// followed by the 65-byte uncompressed point (`0x04 || X(32) || Y(32)`).
/// Scanning for that fixed prefix avoids depending on a general ASN.1/X.509
/// parsing library for a single, well-known field. The identity key is
/// P-256, not Ed25519, because Dart's bundled BoringSSL TLS client was
/// empirically found to reject an Ed25519 server certificate outright
/// during the handshake, even though Go's crypto/tls and OpenSSL both
/// accept it — see ADR-008.
///
/// Using `package:crypto` (rather than the async `package:cryptography` used
/// elsewhere in this client) matters here: certificate verification runs
/// inside `HttpClient.badCertificateCallback`, which is synchronous.
final class ServerFingerprint {
  const ServerFingerprint._();

  static const List<int> _p256SpkiPrefix = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, //
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ];
  static const int _pointLength = 65; // 0x04 || X(32) || Y(32), uncompressed

  /// Returns the lowercase hex SHA-256 fingerprint of the certificate's
  /// P-256 public key, or null if the certificate does not carry a
  /// recognizable P-256 SubjectPublicKeyInfo.
  static String? fromCertificateDer(Uint8List der) {
    final point = _extractP256Point(der);
    if (point == null) return null;
    return sha256.convert(point).toString();
  }

  static Uint8List? _extractP256Point(Uint8List der) {
    final prefixLength = _p256SpkiPrefix.length;
    for (var i = 0; i + prefixLength + _pointLength <= der.length; i++) {
      var matches = true;
      for (var j = 0; j < prefixLength; j++) {
        if (der[i + j] != _p256SpkiPrefix[j]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return Uint8List.sublistView(der, i + prefixLength, i + prefixLength + _pointLength);
      }
    }
    return null;
  }
}
