import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:cryptography/cryptography.dart';

import '../../core/e2ee/file_cipher.dart';
import '../../core/e2ee/key_envelope.dart';
import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/transport/network_errors.dart';

const int homeBoxMaxPlaintextFileSize = 500 * 1024 * 1024;

final class FileIntegrityException implements Exception {
  const FileIntegrityException();

  @override
  String toString() =>
      'Downloaded content failed integrity verification; the file was not saved.';
}

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
  required KeyRing keys,
  required String nodeId,
  String? expectedVersionId,
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
  final version = _selectDownloadVersion(versions, expectedVersionId);
  final versionIdBytes = uuidStringToBytes(version.id);

  final fileKey = await _unwrapFileKey(
    keyEnvelopeCipher,
    keys,
    version,
    versionIdBytes,
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
    versionId: version.id,
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
      throw const FileIntegrityException();
    }
  }

  return plaintextBytes;
}

/// How many times one download call resumes after a dropped connection
/// before reporting the failure.
const int _downloadAttempts = 3;

/// Partial ciphertext older than this is abandoned and removed.
const Duration _stalePartialDownloadAge = Duration(days: 2);

/// Partial ciphertext files currently being written by this process. Only
/// one writer may own a version's resumable file at a time.
final Set<String> _activePartialDownloads = <String>{};

Directory _partialDownloadDirectory() => Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}homebox-downloads',
);

Future<void> _pruneStalePartialDownloads(Directory directory) async {
  final cutoff = DateTime.now().subtract(_stalePartialDownloadAge);
  try {
    await for (final entity in directory.list()) {
      if (entity is! File || _activePartialDownloads.contains(entity.path)) {
        continue;
      }
      if ((await entity.lastModified()).isBefore(cutoff)) {
        await entity.delete();
      }
    }
  } on FileSystemException {
    // Best effort: a locked or vanished leftover must not block a download.
  }
}

/// Streams a download through temporary ciphertext and plaintext files so a
/// maximum-size vault item never has to coexist in memory in encrypted and
/// decrypted form. The destination is replaced only after every AEAD frame
/// and the encrypted metadata's plaintext hash have been verified.
///
/// The ciphertext is kept per file version in the system temp folder. A
/// dropped connection resumes from the bytes already received (within this
/// call, and on a later retry of the same version) instead of starting a
/// large download over. It is ciphertext only and is removed once the file
/// is saved, when verification fails, or after two days.
Future<void> downloadAndDecryptFileToPath({
  required transport.HomeBoxApiClient api,
  required String accessToken,
  required KeyRing keys,
  required String nodeId,
  String? expectedVersionId,
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
  final version = _selectDownloadVersion(versions, expectedVersionId);
  final versionIdBytes = uuidStringToBytes(version.id);
  final fileKey = await _unwrapFileKey(
    keyEnvelopeCipher,
    keys,
    version,
    versionIdBytes,
  );
  final header = E2eeFileHeader.decode(version.e2eeHeader);

  final partialDirectory = _partialDownloadDirectory();
  await partialDirectory.create(recursive: true);
  await _pruneStalePartialDownloads(partialDirectory);
  final resumablePath =
      '${partialDirectory.path}${Platform.pathSeparator}${version.id}.hbxblob.part';
  // A concurrent download of the same version (for example an explicit
  // Save as while the sync folder mirrors it) uses a private file instead
  // of interleaving writes into the shared resumable one.
  final resumable = _activePartialDownloads.add(resumablePath);
  final ciphertextFile = File(
    resumable
        ? resumablePath
        : '${partialDirectory.path}${Platform.pathSeparator}${version.id}-${generateUuidV4()}.hbxblob.part',
  );
  var keepCiphertext = resumable;
  final destination = File(destinationPath);
  final plaintextTemp = File(
    '$destinationPath.homebox-tmp-${generateUuidV4()}',
  );
  try {
    onProgress?.call(0);
    for (var attempt = 1; ; attempt++) {
      try {
        await api.downloadFileContentToFile(
          accessToken,
          nodeId,
          ciphertextFile,
          versionId: version.id,
          onProgress: (progress) => onProgress?.call(progress * 0.9),
          resume: resumable,
        );
        break;
      } catch (e) {
        if (!resumable ||
            attempt >= _downloadAttempts ||
            !isTransientNetworkError(e)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
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
        throw const FormatException(
          'Ciphertext blob has unexpected trailing bytes.',
        );
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
      throw const FileIntegrityException();
    }
    await _replaceVerifiedFile(plaintextTemp, destination);
    keepCiphertext = false;
  } catch (e) {
    // Only an interrupted transfer is worth resuming; ciphertext that
    // failed to decrypt or verify must be fetched again from scratch.
    if (!isTransientNetworkError(e)) keepCiphertext = false;
    rethrow;
  } finally {
    if (await plaintextTemp.exists()) await plaintextTemp.delete();
    if (!keepCiphertext && await ciphertextFile.exists()) {
      await ciphertextFile.delete();
    }
    if (resumable) _activePartialDownloads.remove(resumablePath);
  }
}

/// Unwraps a version's File DEK with the key of the scope it was wrapped
/// in, which may be the owner's Vault Key or a shared folder's key.
Future<SecretKey> _unwrapFileKey(
  KeyEnvelopeCipher cipher,
  KeyRing keys,
  transport.FileVersionInfo version,
  Uint8List versionIdBytes,
) async {
  final scoped = await keys.key(version.keyScopeId, version.keyVersion);
  return cipher.unwrapKey(
    wrappingKey: scoped.key,
    envelope: KeyEnvelope.decode(version.wrappedFileKey),
    scopeId: scoped.scopeIdBytes,
    subjectId: versionIdBytes,
  );
}

/// Wraps a new version's File DEK under [key]. The same key must encrypt
/// the node's metadata, so one version never spans two scopes.
Future<Uint8List> wrapFileKey({
  KeyEnvelopeCipher? cipher,
  required ScopedKey key,
  required SecretKey fileKey,
  required String fileVersionId,
}) async {
  final envelope = await (cipher ?? KeyEnvelopeCipher()).wrapKey(
    wrappingKey: key.key,
    keyToWrap: fileKey,
    purpose: KeyEnvelopePurpose.fileKey,
    keyVersion: key.version,
    scopeId: key.scopeIdBytes,
    subjectId: uuidStringToBytes(fileVersionId),
  );
  return envelope.encode();
}

/// Rewraps an existing version's File DEK from its current scope into
/// [target], for moving content into a shared folder's key (ADR-023). The
/// ciphertext blob never changes.
Future<Uint8List> rewrapFileKey({
  required KeyRing keys,
  required transport.FileVersionInfo version,
  required ScopedKey target,
}) async {
  final cipher = KeyEnvelopeCipher();
  final fileKey = await _unwrapFileKey(
    cipher,
    keys,
    version,
    uuidStringToBytes(version.id),
  );
  try {
    return await wrapFileKey(
      cipher: cipher,
      key: target,
      fileKey: fileKey,
      fileVersionId: version.id,
    );
  } finally {
    fileKey.destroy();
  }
}

transport.FileVersionInfo _selectDownloadVersion(
  List<transport.FileVersionInfo> versions,
  String? expectedVersionId,
) {
  if (expectedVersionId == null) return versions.first;
  for (final version in versions) {
    if (version.id == expectedVersionId) return version;
  }
  throw StateError('The selected file version is no longer available.');
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
/// [key] must be the key [metadataCiphertext] was encrypted with.
Future<transport.NodeInfo> uploadFileVersion({
  required transport.HomeBoxApiClient api,
  required String accessToken,
  required ScopedKey key,
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
  final totalChunks = bytes.isEmpty
      ? 1
      : (bytes.length / homeBoxPlaintextChunkSize).ceil();
  final frames = <Uint8List>[];
  for (var i = 0; i < totalChunks; i++) {
    final start = i * homeBoxPlaintextChunkSize;
    final end = start + homeBoxPlaintextChunkSize < bytes.length
        ? start + homeBoxPlaintextChunkSize
        : bytes.length;
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

  final wrappedFileKey = await wrapFileKey(
    cipher: keyEnvelopeCipher,
    key: key,
    fileKey: fileKey,
    fileVersionId: fileVersionId,
  );

  final uploadSession = await api.createUpload(
    accessToken,
    targetNodeId: targetNodeId,
    fileVersionId: fileVersionId,
    blobId: blobId,
    expectedRevision: expectedRevision,
    chunkSize: homeBoxPlaintextChunkSize + homeBoxChunkMacLength,
    chunkCount: totalChunks,
    metadataKeyVersion: key.version,
    metadataCiphertext: metadataCiphertext,
    wrappedFileKey: wrappedFileKey,
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
    keyScopeId: key.scopeId,
    keyVersion: key.version,
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
  required ScopedKey key,
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
  final wrappedFileKey = await wrapFileKey(
    cipher: keyEnvelopeCipher,
    key: key,
    fileKey: fileKey,
    fileVersionId: fileVersionId,
  );
  final uploadSession = await api.createUpload(
    accessToken,
    targetNodeId: targetNodeId,
    fileVersionId: fileVersionId,
    blobId: blobId,
    expectedRevision: expectedRevision,
    chunkSize: homeBoxPlaintextChunkSize + homeBoxChunkMacLength,
    chunkCount: totalChunks,
    metadataKeyVersion: key.version,
    metadataCiphertext: metadataCiphertext,
    wrappedFileKey: wrappedFileKey,
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
        throw StateError(
          'File changed while HomeBox was encrypting it. Try again.',
        );
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
    throw StateError(
      'File changed while HomeBox was encrypting it. Try again.',
    );
  }
  await api.completeUpload(
    accessToken,
    uploadSession.id,
    operationId: generateUuidV4(),
    keyScopeId: key.scopeId,
    keyVersion: key.version,
    expectedRevision: expectedRevision,
  );
  return api.getNode(accessToken, targetNodeId);
}
