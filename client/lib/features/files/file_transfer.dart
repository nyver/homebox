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
  int? maxCiphertextBytes,
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
    maxBytes: maxCiphertextBytes,
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

/// Streams a download through temporary ciphertext and plaintext files so a
/// maximum-size vault item never has to coexist in memory in encrypted and
/// decrypted form. The destination is replaced only after every AEAD frame
/// and the encrypted metadata's plaintext hash have been verified.
Future<void> downloadAndDecryptFileToPath({
  required transport.HomeBoxApiClient api,
  required String accessToken,
  required SecretKey vaultKey,
  required Uint8List vaultId,
  required String nodeId,
  required String destinationPath,
  String? expectedPlaintextSha256,
  void Function(double progress)? onProgress,
}) async {
  final fileCipher = E2eeFileCipher();
  final keyEnvelopeCipher = KeyEnvelopeCipher();
  final versions = await api.listFileVersions(accessToken, nodeId);
  if (versions.isEmpty) {
    throw StateError('This file has no uploaded content yet.');
  }
  final version = versions.first;
  final versionIdBytes = uuidStringToBytes(version.id);
  final fileKey = await keyEnvelopeCipher.unwrapKey(
    wrappingKey: vaultKey,
    envelope: KeyEnvelope.decode(version.wrappedFileKey),
    scopeId: vaultId,
    subjectId: versionIdBytes,
  );
  final header = E2eeFileHeader.decode(version.e2eeHeader);

  final workDirectory = await Directory.systemTemp.createTemp('homebox-download-');
  final ciphertextFile = File('${workDirectory.path}/ciphertext.hbxblob');
  final destination = File(destinationPath);
  final plaintextTemp = File('$destinationPath.homebox-tmp-${generateUuidV4()}');
  try {
    onProgress?.call(0);
    await api.downloadFileContentToFile(
      accessToken,
      nodeId,
      ciphertextFile,
      onProgress: (progress) => onProgress?.call(progress * 0.9),
    );
    final ciphertextLength = await ciphertextFile.length();
    final fullFrameLength = homeBoxPlaintextChunkSize + homeBoxChunkMacLength;
    final prefixLength = (version.chunkCount - 1) * fullFrameLength;
    final lastFrameLength = ciphertextLength - prefixLength;
    if (version.chunkCount < 1 ||
        prefixLength < 0 ||
        lastFrameLength < homeBoxChunkMacLength ||
        lastFrameLength > fullFrameLength) {
      throw const FormatException(
        'Ciphertext blob length does not match its declared chunk count.',
      );
    }

    await destination.parent.create(recursive: true);
    final digestOutput = _DigestCollector();
    final hashSink = sha256.startChunkedConversion(digestOutput);
    var hashClosed = false;
    final ciphertext = await ciphertextFile.open();
    RandomAccessFile? plaintext;
    try {
      plaintext = await plaintextTemp.open(mode: FileMode.write);
      for (var i = 0; i < version.chunkCount; i++) {
        final frameLength = i == version.chunkCount - 1
            ? lastFrameLength
            : fullFrameLength;
        final frame = await ciphertext.read(frameLength);
        if (frame.length != frameLength) {
          throw const FormatException(
            'Ciphertext blob ended before its declared chunk count.',
          );
        }
        final cleartext = await fileCipher.decryptChunk(
          ciphertextFrame: frame,
          fileKey: fileKey,
          header: header,
          fileVersionId: versionIdBytes,
          chunkNumber: i,
          totalChunks: version.chunkCount,
        );
        hashSink.add(cleartext);
        await plaintext.writeFrom(cleartext);
        onProgress?.call(0.9 + 0.1 * (i + 1) / version.chunkCount);
      }
      if (await ciphertext.position() != ciphertextLength) {
        throw const FormatException('Ciphertext blob has unexpected trailing bytes.');
      }
      hashSink.close();
      hashClosed = true;
      await plaintext.flush();
      await plaintext.close();
      plaintext = null;
    } catch (_) {
      if (!hashClosed) hashSink.close();
      if (plaintext != null) await plaintext.close();
      rethrow;
    } finally {
      await ciphertext.close();
    }

    if (expectedPlaintextSha256 != null &&
        digestOutput.value.toString().toLowerCase() !=
            expectedPlaintextSha256.toLowerCase()) {
      throw StateError(
        'Downloaded content failed integrity verification; the file was not saved.',
      );
    }
    await _replaceVerifiedFile(plaintextTemp, destination);
  } finally {
    if (await plaintextTemp.exists()) await plaintextTemp.delete();
    if (await workDirectory.exists()) await workDirectory.delete(recursive: true);
  }
}

Future<void> _replaceVerifiedFile(File temporary, File destination) async {
  if (!await destination.exists()) {
    await temporary.rename(destination.path);
    return;
  }
  final backup = File('${destination.path}.homebox-old-${generateUuidV4()}');
  await destination.rename(backup.path);
  try {
    await temporary.rename(destination.path);
    await backup.delete();
  } catch (_) {
    if (!await destination.exists() && await backup.exists()) {
      await backup.rename(destination.path);
    }
    rethrow;
  }
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
    expectedRevision: expectedRevision,
    chunkSize: homeBoxPlaintextChunkSize + homeBoxChunkMacLength,
    chunkCount: totalChunks,
    metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
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
    expectedRevision: expectedRevision,
    chunkSize: homeBoxPlaintextChunkSize + homeBoxChunkMacLength,
    chunkCount: totalChunks,
    metadataKeyVersion: homeBoxPersonalVaultKeyVersion,
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
