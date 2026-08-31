import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:cryptography/cryptography.dart';

import '../../core/e2ee/file_cipher.dart';
import '../../core/e2ee/key_envelope.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart' show homeBoxPersonalVaultKeyVersion;
import '../../core/transport/homebox_api_client.dart' as transport;

const int homeBoxMaxPlaintextFileSize = 500 * 1024 * 1024;

/// Hashes a local file incrementally, keeping memory bounded by the stream's
/// chunk size rather than the file size.
Future<String> plaintextFileSha256(File file) async {
  final output = _DigestCollector();
  final sink = sha256.startChunkedConversion(output);
  await for (final bytes in file.openRead()) {
    sink.add(bytes);
  }
  sink.close();
  return output.value.toString();
}

final class _DigestCollector implements Sink<Digest> {
  Digest? _digest;

  @override
  void add(Digest data) {
    if (_digest != null) throw StateError('Digest was emitted more than once.');
    _digest = data;
  }

  @override
  void close() {}

  Digest get value => _digest ?? (throw StateError('Digest was not emitted.'));
}

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

  // Reserve the final 10% for frame decryption and integrity verification.
  // This makes the progress indicator move while ciphertext bytes are still
  // arriving over the network instead of sitting at 0% until the full file
  // has already been received into memory.
  onProgress?.call(0);
  final blob = await api.downloadFileContent(
    accessToken,
    nodeId,
    onProgress: (progress) => onProgress?.call(progress * 0.9),
  );
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
    onProgress?.call(0.9 + 0.1 * (i + 1) / frames.length);
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

/// Encrypts and uploads a local file one 4 MiB frame at a time.
///
/// The caller hashes the file first so encrypted metadata can be created
/// before the node is sent to the server. This second pass hashes the exact
/// bytes being encrypted and aborts the resumable upload if the source file
/// changed between passes, rather than publishing incorrect integrity
/// metadata. At most one plaintext chunk and one ciphertext frame are held in
/// memory.
Future<transport.NodeInfo> uploadFilePathVersion({
  required transport.HomeBoxApiClient api,
  required String accessToken,
  required SecretKey vaultKey,
  required Uint8List vaultId,
  required String keyScopeId,
  required String targetNodeId,
  required int expectedRevision,
  required File file,
  required int plaintextLength,
  required String expectedPlaintextSha256,
  required Uint8List metadataCiphertext,
  void Function(double progress)? onProgress,
}) async {
  if (plaintextLength < 0 || plaintextLength > homeBoxMaxPlaintextFileSize) {
    throw const FormatException('HomeBox files are limited to 500 MiB.');
  }
  final fileCipher = E2eeFileCipher();
  final keyEnvelopeCipher = KeyEnvelopeCipher();
  final fileVersionId = generateUuidV4();
  final blobId = generateUuidV4();
  final fileVersionIdBytes = uuidStringToBytes(fileVersionId);
  final totalChunks = plaintextLength == 0
      ? 1
      : (plaintextLength / homeBoxPlaintextChunkSize).ceil();
  final fileKey = await fileCipher.newFileKey();
  final header = fileCipher.newHeader();
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

  final output = _DigestCollector();
  final hashSink = sha256.startChunkedConversion(output);
  var bytesRead = 0;
  final source = await file.open();
  try {
    for (var i = 0; i < totalChunks; i++) {
      final remaining = plaintextLength - bytesRead;
      final chunkLength = remaining > homeBoxPlaintextChunkSize
          ? homeBoxPlaintextChunkSize
          : remaining;
      final plaintext = await source.read(chunkLength);
      if (plaintext.length != chunkLength) {
        throw StateError('File changed while HomeBox was encrypting it. Try again.');
      }
      bytesRead += plaintext.length;
      hashSink.add(plaintext);
      final frame = await fileCipher.encryptChunk(
        plaintext: plaintext,
        fileKey: fileKey,
        header: header,
        fileVersionId: fileVersionIdBytes,
        chunkNumber: i,
        totalChunks: totalChunks,
      );
      await api.putUploadChunk(accessToken, uploadSession.id, i, frame);
      onProgress?.call((i + 1) / totalChunks);
    }
  } catch (_) {
    try {
      await api.abortUpload(accessToken, uploadSession.id);
    } catch (_) {
      // The server expires an unfinished ciphertext-only session safely.
    }
    rethrow;
  } finally {
    await source.close();
    hashSink.close();
  }

  final actualHash = output.value.toString();
  if (bytesRead != plaintextLength ||
      await file.length() != plaintextLength ||
      actualHash.toLowerCase() != expectedPlaintextSha256.toLowerCase()) {
    try {
      await api.abortUpload(accessToken, uploadSession.id);
    } catch (_) {
      // The server expires an unfinished ciphertext-only session safely.
    }
    throw StateError('File changed while HomeBox was encrypting it. Try again.');
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
