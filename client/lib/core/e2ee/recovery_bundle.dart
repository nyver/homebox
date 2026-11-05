import 'dart:typed_data';

import 'key_envelope.dart';
import 'recovery.dart';

const int homeBoxRecoveryBundleVersion = 1;

/// What the server stores so a Recovery Secret alone can restore a clean
/// device (spec §10.12): the Argon2id-protected [RecoveryPackage] holding the
/// User Master Key, and the Vault Key wrapped by that User Master Key.
///
/// Both halves are ciphertext. Opening the bundle requires the Recovery
/// Secret, which never leaves the user, so the server gains no decryption
/// capability by keeping it.
final class RecoveryBundle {
  RecoveryBundle({
    required this.recoveryPackage,
    required this.wrappedVaultKey,
  }) {
    if (wrappedVaultKey.purpose != KeyEnvelopePurpose.vaultKey) {
      throw ArgumentError(
        'The wrapped Vault Key envelope has the wrong purpose.',
      );
    }
  }

  static const List<int> _magic = [0x48, 0x42, 0x58, 0x42]; // HBXB
  static const int encodedLength =
      4 + 2 + RecoveryPackage.encodedLength + KeyEnvelope.encodedLength;

  final RecoveryPackage recoveryPackage;
  final KeyEnvelope wrappedVaultKey;

  Uint8List encode() {
    final result = Uint8List(encodedLength);
    result.setAll(0, _magic);
    ByteData.sublistView(result)
        .setUint16(4, homeBoxRecoveryBundleVersion, Endian.big);
    result.setAll(6, recoveryPackage.encode());
    result.setAll(6 + RecoveryPackage.encodedLength, wrappedVaultKey.encode());
    return result;
  }

  factory RecoveryBundle.decode(List<int> encoded) {
    if (encoded.length != encodedLength) {
      throw const FormatException('Invalid HomeBox recovery bundle length.');
    }
    final bytes = Uint8List.fromList(encoded);
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) {
        throw const FormatException('Invalid HomeBox recovery bundle magic.');
      }
    }
    final version = ByteData.sublistView(bytes).getUint16(4, Endian.big);
    if (version != homeBoxRecoveryBundleVersion) {
      throw FormatException('Unsupported recovery bundle version: $version.');
    }
    const envelopeOffset = 6 + RecoveryPackage.encodedLength;
    final wrappedVaultKey = KeyEnvelope.decode(
      Uint8List.sublistView(bytes, envelopeOffset),
    );
    if (wrappedVaultKey.purpose != KeyEnvelopePurpose.vaultKey) {
      throw const FormatException('Invalid recovery bundle key envelope.');
    }
    return RecoveryBundle(
      recoveryPackage: RecoveryPackage.decode(
        Uint8List.sublistView(bytes, 6, envelopeOffset),
      ),
      wrappedVaultKey: wrappedVaultKey,
    );
  }
}
