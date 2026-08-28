import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

import '../../core/e2ee/file_cipher.dart';
import '../../core/e2ee/key_envelope.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart' show homeBoxPersonalVaultKeyVersion;
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

/// Encrypts [bytes] with a fresh random File DEK and uploads them as a new
/// file version onto [targetNodeId] (spec §22), driving a resumable-upload
/// session to completion. [targetNodeId] must already exist server-side —
/// this function only ever adds a version to it, never creates a node —
/// and [expectedRevision] must be its current revision, so a concurrent
/// change to the same node surfaces as a `REVISION_CONFLICT` instead of
/// silently overwriting it. Returns the node's state after the upload.
/// Shared by [FilesController.uploadFile] (fresh node, its own first
/// version) and `replaceFileContent` (a new version of an existing node).
Future<transport.NodeInfo> uploadFileVersion({
  required transport.HomeBoxApiClient api,
  required String accessToken,
  required SecretKey vaultKey,
  required Uint8List vaultId,
  required String keyScopeId,
  required String targetNodeId,
  required int expectedRevision,
  required Uint8List bytes,
  required Uint8List metadataCiphertext,
  void Function(double progress)? onProgress,
}) async {
  final fileCipher = E2eeFileCipher();
  final keyEnvelopeCipher = KeyEnvelopeCipher();

  final fileVersionId = generateUuidV4();
  final blobId = generateUuidV4();
  final fileVersionIdBytes = uuidStringToBytes(fileVersionId);

  final fileKey = await fileCipher.newFileKey();
  final header = fileCipher.newHeader();
  final totalChunks = bytes.isEmpty ? 1 : (bytes.length / homeBoxPlaintextChunkSize).ceil();
  final frames = <Uint8List>[];
  for (var i = 0; i < totalChunks; i++) {
    final start = i * homeBoxPlaintextChunkSize;
    final end = start + homeBoxPlaintextChunkSize < bytes.length ? start + homeBoxPlaintextChunkSize : bytes.length;
    final frame = await fileCipher.encryptChunk(
      plaintext: Uint8List.sublistView(bytes, start, end),
      fileKey: fileKey,
      header: header,
      fileVersionId: fileVersionIdBytes,
      chunkNumber: i,
      totalChunks: totalChunks,
    );
    frames.add(frame);
    onProgress?.call((i + 1) / (totalChunks * 2));
  }

  final wrappedFileKey = await keyEnvelopeCipher.wrapKey(
    wrappingKey: vaultKey,
    keyToWrap: fileKey,
    purpose: KeyEnvelopePurpose.fileKey,
    keyVersion: homeBoxPersonalVaultKeyVersion,
    scopeId: vaultId,
    subjectId: fileVersionIdBytes,
  );

  final uploadSession = await api.createUpload(
    accessToken,
    targetNodeId: targetNodeId,
    fileVersionId: fileVersionId,
    blobId: blobId,
    chunkSize: homeBoxPlaintextChunkSize + homeBoxChunkMacLength,
    chunkCount: totalChunks,
    metadataCiphertext: metadataCiphertext,
    wrappedFileKey: wrappedFileKey.encode(),
    e2eeHeader: header.encode(),
  );

  for (var i = 0; i < totalChunks; i++) {
    await api.putUploadChunk(accessToken, uploadSession.id, i, frames[i]);
    onProgress?.call(0.5 + (i + 1) / (totalChunks * 2));
  }

  await api.completeUpload(
    accessToken,
    uploadSession.id,
    operationId: generateUuidV4(),
    keyScopeId: keyScopeId,
    keyVersion: homeBoxPersonalVaultKeyVersion,
    expectedRevision: expectedRevision,
  );

  return api.getNode(accessToken, targetNodeId);
}
