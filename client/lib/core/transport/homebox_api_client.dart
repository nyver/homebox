import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pinned_http_client.dart';

/// Mirrors the spec §18 error envelope `{"error":{"code","message","requestId"}}`.
final class HomeBoxApiException implements Exception {
  const HomeBoxApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String requestId;

  @override
  String toString() => 'HomeBoxApiException($statusCode $code): $message';
}

final class HomeBoxUser {
  const HomeBoxUser({
    required this.id,
    required this.username,
    required this.role,
  });

  final String id;
  final String username;
  final String role;
}

final class HomeBoxDeviceRef {
  const HomeBoxDeviceRef({required this.id, required this.platform});

  final String id;
  final String platform;
}

final class HomeBoxDevice {
  const HomeBoxDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
    required this.keyVersion,
    required this.createdAt,
    required this.lastSeenAt,
    this.lastSyncAt,
    this.revokedAt,
  });

  final String id;
  final String name;
  final String platform;
  final Uint8List publicKey;
  final int keyVersion;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime? lastSyncAt;
  final DateTime? revokedAt;

  bool get isRevoked => revokedAt != null;
}

/// The minimum recipient device data needed to create a Family Vault key
/// envelope. Device names and activity timestamps are intentionally absent.
final class ShareableDevice {
  const ShareableDevice({
    required this.id,
    required this.platform,
    required this.publicKey,
    required this.keyVersion,
  });

  final String id;
  final String platform;
  final Uint8List publicKey;
  final int keyVersion;
}

final class FamilyShareEnvelope {
  const FamilyShareEnvelope({
    required this.targetDeviceId,
    required this.keyVersion,
    required this.ciphertext,
  });

  final String targetDeviceId;
  final int keyVersion;
  final Uint8List ciphertext;

  Map<String, dynamic> toJson() => {
    'targetDeviceId': targetDeviceId,
    'keyVersion': keyVersion,
    'ciphertext': base64Encode(ciphertext),
  };
}

/// An opaque Family Vault READ grant. Its envelopes remain ciphertext until
/// a future per-folder-key layer can safely open them on the recipient.
final class FamilyShare {
  const FamilyShare({
    required this.id,
    required this.nodeId,
    required this.ownerUserId,
    required this.targetUserId,
    required this.permission,
    required this.createdAt,
    required this.envelopes,
  });

  final String id;
  final String nodeId;
  final String ownerUserId;
  final String targetUserId;
  final String permission;
  final DateTime createdAt;
  final List<FamilyShareEnvelope> envelopes;
}

final class HomeBoxSession {
  const HomeBoxSession({
    required this.user,
    required this.device,
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
  });

  final HomeBoxUser user;
  final HomeBoxDeviceRef device;
  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;
}

/// The wire-level device description sent at login (spec §16.1). The device
/// ID is client-generated, matching `DeviceIdentityStore`'s local identity.
final class DeviceRegistration {
  const DeviceRegistration({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
    required this.keyVersion,
  });

  final String id;
  final String name;
  final String platform;
  final Uint8List publicKey;
  final int keyVersion;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'publicKey': base64Encode(publicKey),
    'keyVersion': keyVersion,
  };
}

final class KeyEnvelope {
  const KeyEnvelope({
    required this.id,
    required this.vaultId,
    required this.keyVersion,
    required this.ciphertext,
  });

  final String id;
  final String vaultId;
  final int keyVersion;
  final Uint8List ciphertext;
}

final class NodeInfo {
  const NodeInfo({
    required this.id,
    required this.parentId,
    required this.nodeType,
    required this.metadataCiphertext,
    required this.metadataKeyVersion,
    required this.currentVersionId,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? parentId;
  final String nodeType; // FILE | DIRECTORY
  final Uint8List metadataCiphertext;
  final int metadataKeyVersion;
  final String? currentVersionId;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
}

final class FileVersionInfo {
  const FileVersionInfo({
    required this.id,
    required this.blobId,
    required this.e2eeHeader,
    required this.wrappedFileKey,
    required this.keyScopeId,
    required this.keyVersion,
    required this.revision,
    required this.chunkCount,
  });

  final String id;
  final String blobId;
  final Uint8List e2eeHeader;
  final Uint8List wrappedFileKey;
  final String keyScopeId;
  final int keyVersion;
  final int revision;

  /// How many AEAD chunk frames the ciphertext blob is made of. Needed to
  /// split the concatenated blob (no delimiters in storage) back into
  /// individual frames on decrypt — every chunk but the last is exactly
  /// the fixed plaintext chunk size (ADR-010) plus its AEAD tag.
  final int chunkCount;
}

final class UploadSessionInfo {
  const UploadSessionInfo({
    required this.id,
    required this.chunkCount,
    required this.receivedChunks,
  });

  final String id;
  final int chunkCount;
  final List<int> receivedChunks;
}

final class CompleteUploadResult {
  const CompleteUploadResult({
    required this.blobId,
    required this.fileVersionId,
    required this.revision,
  });

  final String blobId;
  final String fileVersionId;
  final int revision;
}

final class SyncChange {
  const SyncChange({
    required this.revision,
    required this.nodeId,
    required this.operation,
    required this.createdAt,
  });

  final int revision;
  final String? nodeId;
  final String operation;
  final DateTime createdAt;
}

final class SyncPage {
  const SyncPage({
    required this.changes,
    required this.nextAfter,
    required this.hasMore,
  });

  final List<SyncChange> changes;
  final int nextAfter;
  final bool hasMore;
}

/// Talks to the HomeBox server's authenticated business API (spec §17) over
/// a [PinnedHttpClient]. This class only ever moves opaque identifiers and
/// base64 ciphertext blobs — it has no access to, and no dependency on, the
/// E2EE key-unwrapping code in `core/e2ee`, matching the server-side
/// architectural separation described in spec §38.3A.
final class HomeBoxApiClient {
  // Named `baseUrl`/`transport` rather than initializing formals so callers
  // in other files get readable named arguments instead of the private
  // field names.
  HomeBoxApiClient({required Uri baseUrl, required PinnedHttpClient transport})
    // ignore: prefer_initializing_formals
    : _baseUrl = baseUrl,
      // ignore: prefer_initializing_formals
      _transport = transport;

  final Uri _baseUrl;
  final PinnedHttpClient _transport;

  Future<HomeBoxSession> login({
    required String username,
    required String password,
    required DeviceRegistration device,
  }) async {
    final json = await _postJson(
      '/api/v1/auth/login',
      body: {
        'username': username,
        'password': password,
        'device': device.toJson(),
      },
    );
    return _sessionFromJson(json);
  }

  Future<HomeBoxSession> refresh(String refreshToken) async {
    final json = await _postJson(
      '/api/v1/auth/refresh',
      body: {'refreshToken': refreshToken},
    );
    return _sessionFromJson(json);
  }

  Future<void> logout(String refreshToken) => _send(
    'POST',
    '/api/v1/auth/logout',
    body: {'refreshToken': refreshToken},
  );

  Future<HomeBoxUser> me(String accessToken) async {
    final json = await _getJson('/api/v1/users/me', accessToken: accessToken);
    return _userFromJson(json);
  }

  Future<List<HomeBoxDevice>> listDevices(String accessToken) async {
    final body = await _send(
      'GET',
      '/api/v1/devices',
      accessToken: accessToken,
    );
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) => _deviceFromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> revokeDevice(String accessToken, String deviceId) =>
      _send('DELETE', '/api/v1/devices/$deviceId', accessToken: accessToken);

  /// Looks up active recipient public keys after the owner has obtained the
  /// opaque account ID through a deliberate family invite.
  Future<List<ShareableDevice>> listShareableDevices(
    String accessToken,
    String recipientUserId,
  ) async {
    final encodedRecipientUserId = Uri.encodeComponent(recipientUserId);
    final body = await _send(
      'GET',
      '/api/v1/users/$encodedRecipientUserId/share-devices',
      accessToken: accessToken,
    );
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) {
          final json = entry as Map<String, dynamic>;
          return ShareableDevice(
            id: json['id'] as String,
            platform: json['platform'] as String,
            publicKey: base64Decode(json['publicKey'] as String),
            keyVersion: json['keyVersion'] as int,
          );
        })
        .toList(growable: false);
  }

  // --- Family Vault shares ---

  Future<FamilyShare> createReadShare(
    String accessToken, {
    required String operationId,
    required String nodeId,
    required String targetUserId,
    required List<FamilyShareEnvelope> envelopes,
  }) async {
    final json = await _postJson(
      '/api/v1/shares',
      accessToken: accessToken,
      body: {
        'operationId': operationId,
        'nodeId': nodeId,
        'targetUserId': targetUserId,
        'permission': 'READ',
        'envelopes': envelopes
            .map((envelope) => envelope.toJson())
            .toList(growable: false),
      },
    );
    return _familyShareFromJson(json);
  }

  Future<List<FamilyShare>> listIncomingShares(String accessToken) =>
      _listFamilyShares('/api/v1/shares/incoming', accessToken);

  Future<List<FamilyShare>> listOutgoingShares(String accessToken) =>
      _listFamilyShares('/api/v1/shares/outgoing', accessToken);

  Future<void> revokeShare(String accessToken, String shareId) =>
      _send('DELETE', '/api/v1/shares/$shareId', accessToken: accessToken);

  /// Delivers an encrypted key envelope this device wrapped for
  /// [targetDeviceId] (spec §16.2 trusted-device provisioning). Both devices
  /// must belong to the caller's own account; the server enforces this.
  Future<String> uploadKeyEnvelope(
    String accessToken, {
    required String targetDeviceId,
    required String vaultId,
    required int keyVersion,
    required Uint8List ciphertext,
  }) async {
    final json = await _postJson(
      '/api/v1/devices/$targetDeviceId/key-envelope',
      accessToken: accessToken,
      body: {
        'vaultId': vaultId,
        'keyVersion': keyVersion,
        'ciphertext': base64Encode(ciphertext),
      },
    );
    return json['id'] as String;
  }

  /// Downloads this device's own pending key envelope. The server only ever
  /// serves a device its own envelope (spec §16.2); [targetDeviceId] must be
  /// the caller's own device ID.
  Future<KeyEnvelope> downloadKeyEnvelope(
    String accessToken,
    String targetDeviceId,
  ) async {
    final json = await _getJson(
      '/api/v1/devices/$targetDeviceId/key-envelope',
      accessToken: accessToken,
    );
    return KeyEnvelope(
      id: json['id'] as String,
      vaultId: json['vaultId'] as String,
      keyVersion: json['keyVersion'] as int,
      ciphertext: base64Decode(json['ciphertext'] as String),
    );
  }

  // --- nodes ---

  Future<NodeInfo> createNode(
    String accessToken, {
    required String id,
    required String operationId,
    String? parentId,
    required String nodeType,
    required Uint8List metadataCiphertext,
    required int metadataKeyVersion,
  }) async {
    final json = await _postJson(
      '/api/v1/nodes',
      accessToken: accessToken,
      body: {
        'id': id,
        'operationId': operationId,
        'parentId': parentId,
        'nodeType': nodeType,
        'metadataCiphertext': base64Encode(metadataCiphertext),
        'metadataKeyVersion': metadataKeyVersion,
      },
    );
    return _nodeFromJson(json);
  }

  Future<NodeInfo> getNode(String accessToken, String nodeId) async =>
      _nodeFromJson(
        await _getJson('/api/v1/nodes/$nodeId', accessToken: accessToken),
      );

  Future<List<NodeInfo>> listChildren(
    String accessToken, {
    String? parentId,
  }) async {
    final path = parentId == null
        ? '/api/v1/nodes/children'
        : '/api/v1/nodes/children?parentId=$parentId';
    final body = await _send('GET', path, accessToken: accessToken);
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) => _nodeFromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<List<NodeInfo>> listTrash(String accessToken) async {
    final body = await _send('GET', '/api/v1/trash', accessToken: accessToken);
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) => _nodeFromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Renames/moves a node and/or replaces its encrypted metadata (spec
  /// §17.3). Pass [metadataCiphertext] to change the encrypted name/MIME/
  /// hash; pass [moveParent] true (with [parentId] null for root, or a
  /// directory ID) to move it. At least one must be requested.
  Future<NodeInfo> updateNode(
    String accessToken,
    String nodeId, {
    required String operationId,
    required int expectedRevision,
    Uint8List? metadataCiphertext,
    int metadataKeyVersion = 1,
    bool moveParent = false,
    String? parentId,
  }) async {
    final json = await _postJsonMethod(
      'PATCH',
      '/api/v1/nodes/$nodeId',
      accessToken: accessToken,
      body: {
        'operationId': operationId,
        'expectedRevision': expectedRevision,
        if (metadataCiphertext != null)
          'metadataCiphertext': base64Encode(metadataCiphertext),
        if (metadataCiphertext != null)
          'metadataKeyVersion': metadataKeyVersion,
        'moveParent': moveParent,
        'parentId': parentId,
      },
    );
    return _nodeFromJson(json);
  }

  Future<void> deleteNode(
    String accessToken,
    String nodeId, {
    required String operationId,
    required int expectedRevision,
  }) => _send(
    'DELETE',
    '/api/v1/nodes/$nodeId',
    accessToken: accessToken,
    body: {'operationId': operationId, 'expectedRevision': expectedRevision},
  );

  Future<NodeInfo> restoreNode(
    String accessToken,
    String nodeId, {
    required String operationId,
  }) async {
    final json = await _postJson(
      '/api/v1/nodes/$nodeId/restore',
      accessToken: accessToken,
      body: {'operationId': operationId},
    );
    return _nodeFromJson(json);
  }

  // --- sync ---

  Future<SyncPage> syncChanges(
    String accessToken, {
    int after = 0,
    int pageSize = 0,
  }) async {
    final query = pageSize > 0
        ? '?after=$after&pageSize=$pageSize'
        : '?after=$after';
    final body = await _send(
      'GET',
      '/api/v1/sync/changes$query',
      accessToken: accessToken,
    );
    final json = jsonDecode(body) as Map<String, dynamic>;
    final changes = (json['changes'] as List<dynamic>)
        .map((entry) {
          final e = entry as Map<String, dynamic>;
          return SyncChange(
            revision: e['revision'] as int,
            nodeId: e['nodeId'] as String?,
            operation: e['operation'] as String,
            createdAt: DateTime.parse(e['createdAt'] as String),
          );
        })
        .toList(growable: false);
    return SyncPage(
      changes: changes,
      nextAfter: json['nextAfter'] as int,
      hasMore: json['hasMore'] as bool,
    );
  }

  // --- uploads ---

  Future<UploadSessionInfo> createUpload(
    String accessToken, {
    required String targetNodeId,
    required String fileVersionId,
    required String blobId,
    int? expectedRevision,
    required int chunkSize,
    required int chunkCount,
    required Uint8List metadataCiphertext,
    required Uint8List wrappedFileKey,
    required Uint8List e2eeHeader,
  }) async {
    final json = await _postJson(
      '/api/v1/uploads',
      accessToken: accessToken,
      body: {
        'targetNodeId': targetNodeId,
        'fileVersionId': fileVersionId,
        'blobId': blobId,
        'expectedRevision': ?expectedRevision,
        'chunkSize': chunkSize,
        'chunkCount': chunkCount,
        'metadataCiphertext': base64Encode(metadataCiphertext),
        'wrappedFileKey': base64Encode(wrappedFileKey),
        'e2eeHeader': base64Encode(e2eeHeader),
      },
    );
    return UploadSessionInfo(
      id: json['id'] as String,
      chunkCount: json['chunkCount'] as int,
      receivedChunks: (json['receivedChunks'] as List<dynamic>? ?? const [])
          .cast<int>(),
    );
  }

  Future<void> putUploadChunk(
    String accessToken,
    String uploadId,
    int chunkNo,
    Uint8List ciphertext,
  ) => _sendRaw(
    'PUT',
    '/api/v1/uploads/$uploadId/chunks/$chunkNo',
    accessToken: accessToken,
    body: ciphertext,
  );

  Future<CompleteUploadResult> completeUpload(
    String accessToken,
    String uploadId, {
    required String operationId,
    required String keyScopeId,
    required int keyVersion,
    int? expectedRevision,
    Uint8List? syncPayloadCiphertext,
  }) async {
    final encodedPayload = syncPayloadCiphertext != null
        ? base64Encode(syncPayloadCiphertext)
        : null;
    final json = await _postJson(
      '/api/v1/uploads/$uploadId/complete',
      accessToken: accessToken,
      body: {
        'operationId': operationId,
        'keyScopeId': keyScopeId,
        'keyVersion': keyVersion,
        'expectedRevision': ?expectedRevision,
        'syncPayloadCiphertext': ?encodedPayload,
      },
    );
    return CompleteUploadResult(
      blobId: json['blobId'] as String,
      fileVersionId: json['fileVersionId'] as String,
      revision: json['revision'] as int,
    );
  }

  Future<void> abortUpload(String accessToken, String uploadId) =>
      _send('DELETE', '/api/v1/uploads/$uploadId', accessToken: accessToken);

  // --- file content / versions ---

  /// Downloads a node's current-version ciphertext unchanged (spec §23).
  /// The caller must unwrap the File DEK (via [listFileVersions]) and run
  /// it through the E2EE file cipher before this is meaningful plaintext.
  Future<Uint8List> downloadFileContent(
    String accessToken,
    String nodeId, {
    void Function(double progress)? onProgress,
  }) => _sendRaw(
    'GET',
    '/api/v1/files/$nodeId/content',
    accessToken: accessToken,
    onResponseProgress: onProgress,
  );

  Future<List<FileVersionInfo>> listFileVersions(
    String accessToken,
    String nodeId,
  ) async {
    final body = await _send(
      'GET',
      '/api/v1/files/$nodeId/versions',
      accessToken: accessToken,
    );
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) {
          final e = entry as Map<String, dynamic>;
          return FileVersionInfo(
            id: e['id'] as String,
            blobId: e['blobId'] as String,
            e2eeHeader: base64Decode(e['e2eeHeader'] as String),
            wrappedFileKey: base64Decode(e['wrappedFileKey'] as String),
            keyScopeId: e['keyScopeId'] as String,
            keyVersion: e['keyVersion'] as int,
            revision: e['revision'] as int,
            chunkCount: e['chunkCount'] as int,
          );
        })
        .toList(growable: false);
  }

  NodeInfo _nodeFromJson(Map<String, dynamic> json) => NodeInfo(
    id: json['id'] as String,
    parentId: json['parentId'] as String?,
    nodeType: json['nodeType'] as String,
    metadataCiphertext: base64Decode(json['metadataCiphertext'] as String),
    metadataKeyVersion: json['metadataKeyVersion'] as int,
    currentVersionId: json['currentVersionId'] as String?,
    revision: json['revision'] as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    deletedAt: json['deletedAt'] != null
        ? DateTime.parse(json['deletedAt'] as String)
        : null,
  );

  Future<List<FamilyShare>> _listFamilyShares(
    String path,
    String accessToken,
  ) async {
    final body = await _send('GET', path, accessToken: accessToken);
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) => _familyShareFromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  FamilyShare _familyShareFromJson(Map<String, dynamic> json) {
    final envelopes = (json['envelopes'] as List<dynamic>)
        .map((entry) {
          final envelope = entry as Map<String, dynamic>;
          return FamilyShareEnvelope(
            targetDeviceId: envelope['targetDeviceId'] as String,
            keyVersion: envelope['keyVersion'] as int,
            ciphertext: base64Decode(envelope['ciphertext'] as String),
          );
        })
        .toList(growable: false);
    return FamilyShare(
      id: json['id'] as String,
      nodeId: json['nodeId'] as String,
      ownerUserId: json['ownerUserId'] as String,
      targetUserId: json['targetUserId'] as String,
      permission: json['permission'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      envelopes: envelopes,
    );
  }

  Future<Map<String, dynamic>> _postJsonMethod(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
  }) async {
    final response = await _send(
      method,
      path,
      accessToken: accessToken,
      body: body,
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
  }) async {
    final response = await _send(
      'POST',
      path,
      accessToken: accessToken,
      body: body,
    );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    String? accessToken,
  }) async {
    final response = await _send('GET', path, accessToken: accessToken);
    return jsonDecode(response) as Map<String, dynamic>;
  }

  Future<String> _send(
    String method,
    String path, {
    String? accessToken,
    Map<String, dynamic>? body,
  }) async {
    final bytes = await _sendRaw(
      method,
      path,
      accessToken: accessToken,
      body: body != null ? utf8.encode(jsonEncode(body)) : null,
      contentType: 'application/json; charset=utf-8',
    );
    return utf8.decode(bytes);
  }

  /// Sends a request with a raw byte body (used for ciphertext chunk PUTs)
  /// and returns the raw response bytes (used for ciphertext downloads).
  /// [_send] is built on top of this rather than duplicating it, so a
  /// binary download is never accidentally routed through a UTF-8 decode
  /// step that would corrupt it.
  Future<Uint8List> _sendRaw(
    String method,
    String path, {
    String? accessToken,
    List<int>? body,
    String contentType = 'application/octet-stream',
    void Function(double progress)? onResponseProgress,
  }) async {
    final HttpClientResponse response;
    try {
      // The TLS handshake happens during openUrl (connection setup), not
      // during close(), so badCertificateCallback rejections surface here —
      // both calls must be inside this try block.
      final request = await _transport.client.openUrl(
        method,
        _baseUrl.resolve(path),
      );
      if (accessToken != null) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
      }
      if (body != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
        request.add(body);
      }
      response = await request.close();
    } on HandshakeException {
      // badCertificateCallback rejected the server's certificate: either it
      // does not match the pinned fingerprint, or the handshake otherwise
      // failed. Either way this must not be treated as a retryable network
      // error (spec §18 SERVER_IDENTITY_CHANGED).
      throw ServerIdentityMismatchException(_transport.pinnedFingerprint);
    }
    final builder = BytesBuilder(copy: false);
    var received = 0;
    final total = response.contentLength;
    await for (final chunk in response) {
      builder.add(chunk);
      received += chunk.length;
      if (total > 0) onResponseProgress?.call(received / total);
    }
    final responseBytes = builder.takeBytes();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return responseBytes;
    }
    throw _errorFrom(
      response.statusCode,
      utf8.decode(responseBytes, allowMalformed: true),
    );
  }

  HomeBoxApiException _errorFrom(int statusCode, String responseBody) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          return HomeBoxApiException(
            statusCode: statusCode,
            code: error['code'] as String? ?? 'UNKNOWN',
            message: error['message'] as String? ?? 'Request failed',
            requestId: error['requestId'] as String? ?? '',
          );
        }
      }
    } on FormatException {
      // fall through to the generic error below
    }
    return HomeBoxApiException(
      statusCode: statusCode,
      code: 'UNKNOWN',
      message: 'Request failed with status $statusCode',
      requestId: '',
    );
  }

  HomeBoxSession _sessionFromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>;
    final device = json['device'] as Map<String, dynamic>;
    return HomeBoxSession(
      user: HomeBoxUser(
        id: user['id'] as String,
        username: user['username'] as String,
        role: user['role'] as String,
      ),
      device: HomeBoxDeviceRef(
        id: device['id'] as String,
        platform: device['platform'] as String,
      ),
      accessToken: json['accessToken'] as String,
      accessTokenExpiresAt: DateTime.parse(
        json['accessTokenExpiresAt'] as String,
      ),
      refreshToken: json['refreshToken'] as String,
      refreshTokenExpiresAt: DateTime.parse(
        json['refreshTokenExpiresAt'] as String,
      ),
    );
  }

  HomeBoxUser _userFromJson(Map<String, dynamic> json) => HomeBoxUser(
    id: json['id'] as String,
    username: json['username'] as String,
    role: json['role'] as String,
  );

  HomeBoxDevice _deviceFromJson(Map<String, dynamic> json) => HomeBoxDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: json['platform'] as String,
    publicKey: base64Decode(json['publicKey'] as String),
    keyVersion: json['keyVersion'] as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastSeenAt: DateTime.parse(json['lastSeenAt'] as String),
    lastSyncAt: json['lastSyncAt'] != null
        ? DateTime.parse(json['lastSyncAt'] as String)
        : null,
    revokedAt: json['revokedAt'] != null
        ? DateTime.parse(json['revokedAt'] as String)
        : null,
  );
}
