import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

import '../../core/e2ee/file_cipher.dart';
import '../../core/e2ee/key_envelope.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/transport/homebox_api_client.dart' as transport;

/// Downloads a file node's current version and decrypts it (spec §23):
/// unwraps the File DEK from the newest version's key envelope, splits the
/// downloaded ciphertext blob back into its AEAD frames (storage has no
/// per-chunk delimiters, so the frame count comes from the server's
/// file-version descriptor), decrypts each one, and — if [expectedPlaintextSha256]
/// is given — verifies it against the encrypted metadata's recorded hash
/// before returning anything. Shared by [FilesController.downloadFile]
/// (save to a user-chosen path) and `SyncFolderMaterializer` (mirror to the
/// local sync folder) so both decrypt frames identically.
Future<Uint8List> downloadAndDecryptFile({
  required transport.HomeBoxApiClient api,
  required String accessToken,
  required SecretKey vaultKey,
  required Uint8List vaultId,
  required String nodeId,
  String? expectedPlaintextSha256,
  void Function(double progress)? onProgress,
}) async {
  final fileCipher = E2eeFileCipher();
  final keyEnvelopeCipher = KeyEnvelopeCipher();

  final versions = await api.listFileVersions(accessToken, nodeId);
  if (versions.isEmpty) {
    throw StateError('This file has no uploaded content yet.');
  }
  final version = versions.first; // newest first, per the server's ordering.
  final versionIdBytes = uuidStringToBytes(version.id);

  final fileKey = await keyEnvelopeCipher.unwrapKey(
    wrappingKey: vaultKey,
    envelope: KeyEnvelope.decode(version.wrappedFileKey),
    scopeId: vaultId,
    subjectId: versionIdBytes,
  );
  final header = E2eeFileHeader.decode(version.e2eeHeader);

  final blob = await api.downloadFileContent(accessToken, nodeId);
  final frames = splitChunkFrames(blob, chunkCount: version.chunkCount);

  final output = BytesBuilder(copy: false);
  for (var i = 0; i < frames.length; i++) {
    final plaintext = await fileCipher.decryptChunk(
      ciphertextFrame: frames[i],
      fileKey: fileKey,
      header: header,
      fileVersionId: versionIdBytes,
      chunkNumber: i,
      totalChunks: frames.length,
    );
    output.add(plaintext);
    onProgress?.call((i + 1) / frames.length);
  }
  final plaintextBytes = output.takeBytes();

  if (expectedPlaintextSha256 != null) {
    final actualHash = sha256.convert(plaintextBytes).toString();
    if (actualHash.toLowerCase() != expectedPlaintextSha256.toLowerCase()) {
      throw StateError('Downloaded content failed integrity verification; the file was not saved.');
    }
  }

  return plaintextBytes;
}
