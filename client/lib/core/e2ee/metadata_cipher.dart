import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:homebox_client/core/e2ee/portable_name.dart';

const int homeBoxMetadataVersion = 1;
const int homeBoxMetadataNonceLength = 24;
const int homeBoxMetadataMacLength = 16;
const int homeBoxMetadataMaximumPlaintextLength = 64 * 1024;

enum MetadataNodeType {
  file(1),
  directory(2);

  const MetadataNodeType(this.code);
  final int code;
}

final class SensitiveNodeMetadata {
  SensitiveNodeMetadata({
    required String fileName,
    this.mimeType,
    this.plaintextSha256,
    this.conflictDetails,
    List<String> labels = const [],
  }) : fileName = PortableName.normalizeAndValidate(fileName),
       labels = List.unmodifiable(labels) {
    if (mimeType != null && (mimeType!.isEmpty || mimeType!.length > 255)) {
      throw const FormatException(
        'MIME type must contain 1 to 255 characters.',
      );
    }
    if (plaintextSha256 != null &&
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(plaintextSha256!)) {
      throw const FormatException(
        'Plaintext SHA-256 must be 64 hexadecimal characters.',
      );
    }
    if (conflictDetails != null && conflictDetails!.length > 4096) {
      throw const FormatException('Conflict details are too long.');
    }
    if (this.labels.length > 32 ||
        this.labels.any((label) => label.isEmpty || label.length > 64)) {
      throw const FormatException('Metadata labels are invalid.');
    }
  }

  final String fileName;
  final String? mimeType;
  final String? plaintextSha256;
  final String? conflictDetails;
  final List<String> labels;

  Map<String, Object?> toJson() => <String, Object?>{
    'filename': fileName,
    if (mimeType != null) 'mimeType': mimeType,
    if (plaintextSha256 != null)
      'plaintextSha256': plaintextSha256!.toLowerCase(),
    if (conflictDetails != null) 'conflictDetails': conflictDetails,
    if (labels.isNotEmpty) 'labels': labels,
  };

  factory SensitiveNodeMetadata.fromJson(Map<String, Object?> json) {
    final fileName = json['filename'];
    final labelsValue = json['labels'];
    if (fileName is! String) {
      throw const FormatException('Encrypted metadata has an invalid schema.');
    }
    final List<Object?> rawLabels;
    if (labelsValue == null) {
      rawLabels = const [];
    } else if (labelsValue is List<Object?>) {
      rawLabels = labelsValue;
    } else {
      throw const FormatException('Encrypted metadata labels are invalid.');
    }
    final labels = rawLabels
        .map((value) {
          if (value is! String) {
            throw const FormatException('Encrypted metadata label is invalid.');
          }
          return value;
        })
        .toList(growable: false);
    return SensitiveNodeMetadata(
      fileName: fileName,
      mimeType: _optionalString(json, 'mimeType'),
      plaintextSha256: _optionalString(json, 'plaintextSha256'),
      conflictDetails: _optionalString(json, 'conflictDetails'),
      labels: labels,
    );
  }

  static String? _optionalString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value != null && value is! String) {
      throw FormatException('Encrypted metadata field $key is invalid.');
    }
    return value as String?;
  }
}

final class EncryptedMetadataEnvelope {
  EncryptedMetadataEnvelope({
    required this.keyVersion,
    required List<int> nonce,
    required List<int> ciphertext,
    required List<int> mac,
  }) : _nonce = Uint8List.fromList(nonce),
       _ciphertext = Uint8List.fromList(ciphertext),
       _mac = Uint8List.fromList(mac) {
    if (keyVersion < 1 || keyVersion > 0xffffffff) {
      throw ArgumentError.value(keyVersion, 'keyVersion');
    }
    if (_nonce.length != homeBoxMetadataNonceLength ||
        _mac.length != homeBoxMetadataMacLength ||
        _ciphertext.length > homeBoxMetadataMaximumPlaintextLength) {
      throw ArgumentError('Invalid encrypted metadata component length.');
    }
  }

  static const List<int> _magic = [0x48, 0x42, 0x58, 0x4d]; // HBXM

  final int keyVersion;
  final Uint8List _nonce;
  final Uint8List _ciphertext;
  final Uint8List _mac;

  Uint8List encode() {
    final result = Uint8List(4 + 2 + 4 + 24 + 4 + _ciphertext.length + 16);
    result.setAll(0, _magic);
    final data = ByteData.sublistView(result);
    data.setUint16(4, homeBoxMetadataVersion, Endian.big);
    data.setUint32(6, keyVersion, Endian.big);
    result.setAll(10, _nonce);
    data.setUint32(34, _ciphertext.length, Endian.big);
    result.setAll(38, _ciphertext);
    result.setAll(38 + _ciphertext.length, _mac);
    return result;
  }

  factory EncryptedMetadataEnvelope.decode(List<int> encoded) {
    const fixedLength = 4 + 2 + 4 + 24 + 4 + 16;
    if (encoded.length < fixedLength ||
        encoded.length > fixedLength + homeBoxMetadataMaximumPlaintextLength) {
      throw const FormatException(
        'Invalid encrypted metadata envelope length.',
      );
    }
    final bytes = Uint8List.fromList(encoded);
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) {
        throw const FormatException('Invalid encrypted metadata magic.');
      }
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint16(4, Endian.big);
    if (version != homeBoxMetadataVersion) {
      throw FormatException(
        'Unsupported encrypted metadata version: $version.',
      );
    }
    final keyVersion = data.getUint32(6, Endian.big);
    final ciphertextLength = data.getUint32(34, Endian.big);
    if (keyVersion < 1 || encoded.length != fixedLength + ciphertextLength) {
      throw const FormatException('Encrypted metadata framing is invalid.');
    }
    return EncryptedMetadataEnvelope(
      keyVersion: keyVersion,
      nonce: Uint8List.sublistView(bytes, 10, 34),
      ciphertext: Uint8List.sublistView(bytes, 38, 38 + ciphertextLength),
      mac: Uint8List.sublistView(bytes, 38 + ciphertextLength),
    );
  }
}

final class MetadataCipher {
  MetadataCipher({Xchacha20? algorithm})
    : _algorithm = algorithm ?? Xchacha20.poly1305Aead();

  final Xchacha20 _algorithm;

  Future<EncryptedMetadataEnvelope> encrypt({
    required SensitiveNodeMetadata metadata,
    required SecretKey metadataKey,
    required int keyVersion,
    required MetadataNodeType nodeType,
    required Uint8List scopeId,
    required Uint8List nodeId,
  }) async {
    _validateContext(keyVersion, scopeId, nodeId);
    final plaintext = Uint8List.fromList(
      utf8.encode(jsonEncode(metadata.toJson())),
    );
    try {
      if (plaintext.length > homeBoxMetadataMaximumPlaintextLength) {
        throw const FormatException(
          'Encrypted metadata plaintext is too large.',
        );
      }
      final nonce = _algorithm.newNonce();
      final box = await _algorithm.encrypt(
        plaintext,
        secretKey: metadataKey,
        nonce: nonce,
        aad: _aad(keyVersion, nodeType, scopeId, nodeId),
      );
      return EncryptedMetadataEnvelope(
        keyVersion: keyVersion,
        nonce: nonce,
        ciphertext: box.cipherText,
        mac: box.mac.bytes,
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  Future<SensitiveNodeMetadata> decrypt({
    required EncryptedMetadataEnvelope envelope,
    required SecretKey metadataKey,
    required MetadataNodeType nodeType,
    required Uint8List scopeId,
    required Uint8List nodeId,
  }) async {
    _validateContext(envelope.keyVersion, scopeId, nodeId);
    final plaintext = await _algorithm.decrypt(
      SecretBox(
        envelope._ciphertext,
        nonce: envelope._nonce,
        mac: Mac(envelope._mac),
      ),
      secretKey: metadataKey,
      aad: _aad(envelope.keyVersion, nodeType, scopeId, nodeId),
    );
    try {
      final decoded = jsonDecode(utf8.decode(plaintext, allowMalformed: false));
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Encrypted metadata root is invalid.');
      }
      return SensitiveNodeMetadata.fromJson(decoded);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  Uint8List _aad(
    int keyVersion,
    MetadataNodeType nodeType,
    Uint8List scopeId,
    Uint8List nodeId,
  ) {
    final result = Uint8List(4 + 2 + 4 + 1 + 16 + 16);
    result.setAll(0, const [0x48, 0x42, 0x58, 0x4e]); // HBXN
    final data = ByteData.sublistView(result);
    data.setUint16(4, homeBoxMetadataVersion, Endian.big);
    data.setUint32(6, keyVersion, Endian.big);
    data.setUint8(10, nodeType.code);
    result.setAll(11, scopeId);
    result.setAll(27, nodeId);
    return result;
  }

  void _validateContext(int keyVersion, Uint8List scopeId, Uint8List nodeId) {
    if (keyVersion < 1 || keyVersion > 0xffffffff) {
      throw ArgumentError.value(keyVersion, 'keyVersion');
    }
    if (scopeId.length != 16 || nodeId.length != 16) {
      throw ArgumentError('Scope and node IDs must be 16-byte opaque UUIDs.');
    }
  }
}
