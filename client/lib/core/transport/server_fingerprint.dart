import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

/// Extracts the raw P-256 public key point from an X.509 certificate
/// encoded in DER and returns its SHA-256 fingerprint as lowercase hex,
/// matching the server's `serveridentity.Identity.Fingerprint()` /
/// `FingerprintFromPublicKey` (ADR-008/ADR-009).
///
/// HomeBox certificates carry an ECDSA P-256 SubjectPublicKeyInfo. This
/// parser walks the certificate's DER structure to that exact field before
/// accepting the algorithm, curve, and uncompressed point. Searching the raw
/// certificate for a byte pattern is not sufficient: an unrelated extension
/// could contain a copy of the pinned public point while the TLS handshake is
/// authenticated by a different key. The identity key is
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

  static const List<int> _p256AlgorithmIdentifier = [
    0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
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
    try {
      final certificate = _DerReader(der);
      final certificateSequence = certificate.read(0x30);
      if (!certificate.isAtEnd) return null;

      final certificateFields = certificateSequence.reader();
      final tbsCertificate = certificateFields.read(0x30);
      certificateFields.read(0x30); // signatureAlgorithm
      certificateFields.read(0x03); // signatureValue
      if (!certificateFields.isAtEnd) return null;

      final tbs = tbsCertificate.reader();
      if (tbs.peekTag == 0xa0) tbs.read(0xa0); // optional explicit version
      tbs.read(0x02); // serialNumber
      tbs.read(0x30); // signature
      tbs.read(0x30); // issuer
      tbs.read(0x30); // validity
      tbs.read(0x30); // subject
      final subjectPublicKeyInfo = tbs.read(0x30).reader();

      final algorithm = subjectPublicKeyInfo.read(0x30).content;
      if (!_constantBytesEqual(algorithm, _p256AlgorithmIdentifier)) return null;
      final publicKeyBits = subjectPublicKeyInfo.read(0x03).content;
      if (!subjectPublicKeyInfo.isAtEnd ||
          publicKeyBits.length != _pointLength + 1 ||
          publicKeyBits[0] != 0 ||
          publicKeyBits[1] != 0x04) {
        return null;
      }
      return Uint8List.sublistView(publicKeyBits, 1);
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }
}

bool _constantBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var i = 0; i < left.length; i++) {
    difference |= left[i] ^ right[i];
  }
  return difference == 0;
}

final class _DerValue {
  const _DerValue(this.content);

  final Uint8List content;

  _DerReader reader() => _DerReader(content);
}

/// Minimal strict DER reader for the fixed X.509 path needed above. It does
/// not attempt to interpret arbitrary ASN.1 values.
final class _DerReader {
  _DerReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get isAtEnd => _offset == _bytes.length;
  int? get peekTag => isAtEnd ? null : _bytes[_offset];

  _DerValue read(int expectedTag) {
    if (_offset >= _bytes.length || _bytes[_offset++] != expectedTag) {
      throw const FormatException('Unexpected DER tag.');
    }
    if (_offset >= _bytes.length) {
      throw const FormatException('Missing DER length.');
    }
    var length = _bytes[_offset++];
    if ((length & 0x80) != 0) {
      final lengthBytes = length & 0x7f;
      if (lengthBytes == 0 || lengthBytes > 4 || _offset + lengthBytes > _bytes.length) {
        throw const FormatException('Invalid DER length.');
      }
      if (_bytes[_offset] == 0) {
        throw const FormatException('Non-minimal DER length.');
      }
      length = 0;
      for (var i = 0; i < lengthBytes; i++) {
        length = (length << 8) | _bytes[_offset++];
      }
      if (length < 128) {
        throw const FormatException('Non-minimal DER length.');
      }
    }
    final end = _offset + length;
    if (end < _offset || end > _bytes.length) {
      throw const FormatException('DER value exceeds its container.');
    }
    final content = Uint8List.sublistView(_bytes, _offset, end);
    _offset = end;
    return _DerValue(content);
  }
}
