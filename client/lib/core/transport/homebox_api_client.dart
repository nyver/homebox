import 'dart:async';
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
    this.hasVaultKey = false,
    this.authentication,
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

  /// True once a trusted device has delivered this device a vault-key
  /// envelope that has not since been revoked. This is the only reliable
  /// approval signal: a device can log in and even read the (still
  /// undecryptable) sync feed before ever being approved, so login or sync
  /// activity alone must never be shown as approval.
  final bool hasVaultKey;

  /// Ed25519 account certificate for this exact X25519 key. Null identifies
  /// a legacy or not-yet-approved device and is never treated as verified.
  final DeviceKeyAuthentication? authentication;

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
    this.authentication,
  });

  final String id;
  final String platform;
  final Uint8List publicKey;
  final int keyVersion;
  final DeviceKeyAuthentication? authentication;
}

final class DeviceKeyAuthentication {
  const DeviceKeyAuthentication({
    required this.signatureVersion,
    required this.deviceKeyVersion,
    required this.accountIdentityPublicKey,
    required this.publicKeySignature,
  });

  final int signatureVersion;
  final int deviceKeyVersion;
  final Uint8List accountIdentityPublicKey;
  final Uint8List publicKeySignature;
}

/// One folder-key version encrypted for one recipient device, signed by the
/// owner's account identity so the recipient can tell it was not forged by
/// the server (ADR-023). Envelopes from before signing have no signature.
final class FamilyShareEnvelope {
  const FamilyShareEnvelope({
    required this.targetDeviceId,
    required this.keyVersion,
    required this.ciphertext,
    this.ownerIdentityPublicKey,
    this.ownerSignature,
  });

  final String targetDeviceId;
  final int keyVersion;
  final Uint8List ciphertext;
  final Uint8List? ownerIdentityPublicKey;
  final Uint8List? ownerSignature;

  Map<String, dynamic> toJson() => {
    'targetDeviceId': targetDeviceId,
    'keyVersion': keyVersion,
    'ciphertext': base64Encode(ciphertext),
    if (ownerIdentityPublicKey != null)
      'ownerIdentityPublicKey': base64Encode(ownerIdentityPublicKey!),
    if (ownerSignature != null) 'ownerSignature': base64Encode(ownerSignature!),
  };
}

/// Family Vault share permissions (spec §28).
abstract final class SharePermission {
  static const String read = 'READ';
  static const String readWrite = 'READ_WRITE';
}

/// A Family Vault folder grant. The envelopes stay ciphertext until the
/// recipient device opens them with its own private key.
final class FamilyShare {
  const FamilyShare({
    required this.id,
    required this.nodeId,
    required this.ownerUserId,
    required this.targetUserId,
    required this.permission,
    required this.createdAt,
    required this.envelopes,
    this.ownerUsername = '',
    this.targetUsername = '',
  });

  final String id;
  final String nodeId;
  final String ownerUserId;
  final String targetUserId;
  final String permission;
  final DateTime createdAt;
  final List<FamilyShareEnvelope> envelopes;
  final String ownerUsername;
  final String targetUsername;

  bool get canWrite => permission == SharePermission.readWrite;
}

/// One version of a shared folder's key, wrapped by the owner's Vault Key.
final class FolderKeyRecord {
  const FolderKeyRecord({
    required this.folderId,
    required this.keyVersion,
    required this.ownerEnvelope,
  });

  final String folderId;
  final int keyVersion;
  final Uint8List ownerEnvelope;
}

/// One file version's File DEK rewrapped under another key scope.
final class RekeyFileVersion {
  const RekeyFileVersion({
    required this.id,
    required this.wrappedFileKey,
    required this.keyScopeId,
    required this.keyVersion,
  });

  final String id;
  final Uint8List wrappedFileKey;
  final String keyScopeId;
  final int keyVersion;

  Map<String, dynamic> toJson() => {
    'id': id,
    'wrappedFileKey': base64Encode(wrappedFileKey),
    'keyScopeId': keyScopeId,
    'keyVersion': keyVersion,
  };
}

/// One node moved into another key scope by [HomeBoxApiClient.rekeyNodes].
final class RekeyItem {
  const RekeyItem({
    required this.nodeId,
    required this.expectedRevision,
    required this.metadataCiphertext,
    required this.metadataKeyVersion,
    required this.metadataKeyScopeId,
    this.fileVersions = const [],
  });

  final String nodeId;
  final int expectedRevision;
  final Uint8List metadataCiphertext;
  final int metadataKeyVersion;
  final String metadataKeyScopeId;
  final List<RekeyFileVersion> fileVersions;

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'expectedRevision': expectedRevision,
    'metadataCiphertext': base64Encode(metadataCiphertext),
    'metadataKeyVersion': metadataKeyVersion,
    'metadataKeyScopeId': metadataKeyScopeId,
    'fileVersions': fileVersions
        .map((version) => version.toJson())
        .toList(growable: false),
  };
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
    this.deviceKeyAuthentication,
  });

  final String id;
  final String vaultId;
  final int keyVersion;
  final Uint8List ciphertext;
  final DeviceKeyAuthentication? deviceKeyAuthentication;
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
    this.metadataKeyScopeId,
  });

  final String id;
  final String? parentId;
  final String nodeType; // FILE | DIRECTORY
  final Uint8List metadataCiphertext;
  final int metadataKeyVersion;

  /// The key scope of [metadataCiphertext]: the owner's account ID for its
  /// personal Vault Key, or a shared folder's ID (ADR-023). Null only from
  /// a server that predates Family Vault folder keys, which means the
  /// owner's Vault Key.
  final String? metadataKeyScopeId;
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
    this.createdAt,
    this.ciphertextSize,
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

  /// When this version was uploaded. Null only from a server that predates
  /// the field.
  final DateTime? createdAt;

  /// The stored ciphertext size; the plaintext is slightly smaller.
  final int? ciphertextSize;
}

/// The account's opaque recovery bundle as stored by the server.
final class RecoveryBundleRecord {
  const RecoveryBundleRecord({
    required this.bundle,
    required this.updatedAt,
    required this.updatedByDeviceId,
  });

  final Uint8List bundle;
  final DateTime updatedAt;
  final String updatedByDeviceId;
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

  /// Bounds connection setup plus the TLS handshake.
  static const Duration _connectTimeout = Duration(seconds: 30);

  /// Bounds the wait for response headers. Generous because completing a
  /// maximum-size upload makes the server assemble and fsync 500 MiB.
  static const Duration _responseTimeout = Duration(minutes: 3);

  /// Fails a response body that stops delivering bytes. Without it a
  /// stalled connection on a flaky mobile network leaves sync "busy"
  /// forever instead of going offline and retrying.
  static const Duration _idleTimeout = Duration(seconds: 60);

  /// Page size for directory listings; the server caps it at 1000.
  static const int _listPageSize = 500;

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
            authentication: _deviceKeyAuthenticationFromJson(
              json,
              deviceKeyVersion: json['keyVersion'] as int,
            ),
          );
        })
        .toList(growable: false);
  }

  // --- Family Vault shares ---

  /// Shares an already keyed folder with [targetUserId] (spec §28).
  /// [permission] is [SharePermission.read] or [SharePermission.readWrite].
  Future<FamilyShare> createShare(
    String accessToken, {
    required String operationId,
    required String nodeId,
    required String targetUserId,
    required String permission,
    required List<FamilyShareEnvelope> envelopes,
  }) async {
    final json = await _postJson(
      '/api/v1/shares',
      accessToken: accessToken,
      body: {
        'operationId': operationId,
        'nodeId': nodeId,
        'targetUserId': targetUserId,
        'permission': permission,
        'envelopes': envelopes
            .map((envelope) => envelope.toJson())
            .toList(growable: false),
      },
    );
    return _familyShareFromJson(json);
  }

  /// Delivers additional folder-key envelopes for an existing share: to a
  /// recipient device approved later, or a rotated key version.
  Future<FamilyShare> addShareEnvelopes(
    String accessToken,
    String shareId, {
    required List<FamilyShareEnvelope> envelopes,
  }) async {
    final json = await _postJson(
      '/api/v1/shares/$shareId/envelopes',
      accessToken: accessToken,
      body: {
        'envelopes': envelopes
            .map((envelope) => envelope.toJson())
            .toList(growable: false),
      },
    );
    return _familyShareFromJson(json);
  }

  /// Stores [keyVersion] of [folderId]'s key wrapped by the owner's Vault
  /// Key. Version 1 turns the folder into its own key scope.
  Future<void> createFolderKey(
    String accessToken,
    String folderId, {
    required int keyVersion,
    required Uint8List ownerEnvelope,
  }) => _postJson(
    '/api/v1/nodes/$folderId/folder-keys',
    accessToken: accessToken,
    body: {
      'keyVersion': keyVersion,
      'ownerEnvelope': base64Encode(ownerEnvelope),
    },
  );

  Future<List<FolderKeyRecord>> listFolderKeys(String accessToken) async {
    final body = await _send(
      'GET',
      '/api/v1/folder-keys',
      accessToken: accessToken,
    );
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) {
          final json = entry as Map<String, dynamic>;
          return FolderKeyRecord(
            folderId: json['folderId'] as String,
            keyVersion: json['keyVersion'] as int,
            ownerEnvelope: base64Decode(json['ownerEnvelope'] as String),
          );
        })
        .toList(growable: false);
  }

  /// Moves existing nodes into another key scope with metadata and File
  /// DEKs re-encrypted on this device (ADR-023). At most 200 per call.
  Future<List<NodeInfo>> rekeyNodes(
    String accessToken,
    List<RekeyItem> items,
  ) async {
    final body = await _send(
      'POST',
      '/api/v1/nodes/rekey',
      accessToken: accessToken,
      body: {
        'items': items.map((item) => item.toJson()).toList(growable: false),
      },
    );
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) => _nodeFromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
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
    DeviceKeyAuthentication? deviceKeyAuthentication,
  }) async {
    final json = await _postJson(
      '/api/v1/devices/$targetDeviceId/key-envelope',
      accessToken: accessToken,
      body: {
        'vaultId': vaultId,
        'keyVersion': keyVersion,
        'ciphertext': base64Encode(ciphertext),
        if (deviceKeyAuthentication != null) ...{
          'signatureVersion': deviceKeyAuthentication.signatureVersion,
          'accountIdentityPublicKey': base64Encode(
            deviceKeyAuthentication.accountIdentityPublicKey,
          ),
          'publicKeySignature': base64Encode(
            deviceKeyAuthentication.publicKeySignature,
          ),
        },
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
      deviceKeyAuthentication: _deviceKeyAuthenticationFromJson(
        json,
        deviceKeyVersion: json['deviceKeyVersion'] as int?,
      ),
    );
  }

  /// Returns this account's recovery bundle, or null when none is stored.
  Future<RecoveryBundleRecord?> getRecoveryBundle(String accessToken) async {
    final Map<String, dynamic> json;
    try {
      json = await _getJson(
        '/api/v1/users/me/recovery',
        accessToken: accessToken,
      );
    } on HomeBoxApiException catch (e) {
      if (e.statusCode == HttpStatus.notFound) return null;
      rethrow;
    }
    return RecoveryBundleRecord(
      bundle: base64Decode(json['bundle'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      updatedByDeviceId: json['updatedByDeviceId'] as String,
    );
  }

  /// Stores or replaces this account's recovery bundle. [signature] is the
  /// account identity's signature over the bundle (see
  /// `AccountIdentity.signRecoveryBundle`).
  Future<void> putRecoveryBundle(
    String accessToken, {
    required Uint8List bundle,
    required Uint8List accountIdentityPublicKey,
    required Uint8List signature,
  }) => _send(
    'PUT',
    '/api/v1/users/me/recovery',
    accessToken: accessToken,
    body: {
      'bundle': base64Encode(bundle),
      'accountIdentityPublicKey': base64Encode(accountIdentityPublicKey),
      'signature': base64Encode(signature),
    },
  );

  // --- nodes ---

  Future<NodeInfo> createNode(
    String accessToken, {
    required String id,
    required String operationId,
    String? parentId,
    required String nodeType,
    required Uint8List metadataCiphertext,
    required int metadataKeyVersion,
    String? metadataKeyScopeId,
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
        'metadataKeyScopeId': ?metadataKeyScopeId,
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
    bool ownedOnly = false,
  }) async {
    final nodes = <NodeInfo>[];
    String? after;
    do {
      final query = <String, String>{
        'parentId': ?parentId,
        if (parentId == null && ownedOnly) 'ownedOnly': 'true',
        'limit': '$_listPageSize',
        'after': ?after,
      };
      final response = await _sendRawWithHeaders(
        'GET',
        Uri(path: '/api/v1/nodes/children', queryParameters: query).toString(),
        accessToken: accessToken,
      );
      final decoded = jsonDecode(utf8.decode(response.body)) as List<dynamic>;
      nodes.addAll(
        decoded.map((entry) => _nodeFromJson(entry as Map<String, dynamic>)),
      );
      // A server that predates pagination ignores `limit` and sends no
      // cursor, which ends the loop after its complete single response.
      after = response.headers.value('x-next-after');
    } while (after != null && after.isNotEmpty);
    return List.unmodifiable(nodes);
  }

  Future<List<NodeInfo>> listTrash(String accessToken) async {
    final body = await _send('GET', '/api/v1/trash', accessToken: accessToken);
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((entry) => _nodeFromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Permanently deletes one of this account's Trash entries and its whole
  /// subtree now, instead of after the server's Trash retention period.
  Future<void> purgeTrashEntry(String accessToken, String nodeId) =>
      _send('DELETE', '/api/v1/trash/$nodeId', accessToken: accessToken);

  // --- favorites (spec §29) ---

  /// IDs of this account's favorite nodes it can currently see, newest
  /// first.
  Future<List<String>> listFavorites(String accessToken) async {
    final body = await _send(
      'GET',
      '/api/v1/favorites',
      accessToken: accessToken,
    );
    final decoded = jsonDecode(body) as List<dynamic>;
    return [
      for (final entry in decoded)
        (entry as Map<String, dynamic>)['nodeId'] as String,
    ];
  }

  /// Marks [nodeId] as a favorite; adding it again is harmless.
  Future<void> addFavorite(String accessToken, String nodeId) =>
      _send('PUT', '/api/v1/favorites/$nodeId', accessToken: accessToken);

  /// Unmarks [nodeId]; removing a missing favorite is harmless.
  Future<void> removeFavorite(String accessToken, String nodeId) =>
      _send('DELETE', '/api/v1/favorites/$nodeId', accessToken: accessToken);

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
    String? metadataKeyScopeId,
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
        if (metadataCiphertext != null)
          'metadataKeyScopeId': ?metadataKeyScopeId,
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
    required int metadataKeyVersion,
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
        'metadataKeyVersion': metadataKeyVersion,
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
    String? versionId,
    void Function(double progress)? onProgress,
    int? maxBytes,
  }) => _sendRaw(
    'GET',
    _fileContentPath(nodeId, versionId),
    accessToken: accessToken,
    onResponseProgress: onProgress,
    maxResponseBytes: maxBytes,
  );

  /// Streams ciphertext to [destination] with bounded memory. Production
  /// file downloads use this path; the byte-returning method above remains
  /// for small previews and transport-level tests.
  ///
  /// With [resume] and a [versionId], bytes already in [destination] from an
  /// interrupted attempt are kept and only the remainder is requested. The
  /// version ID is the blob's ETag, so a server that no longer serves that
  /// exact ciphertext answers with the full body instead of a range, and
  /// the partial file is replaced rather than spliced with other content.
  /// A failed resumable download leaves its partial file for the next try.
  Future<void> downloadFileContentToFile(
    String accessToken,
    String nodeId,
    File destination, {
    String? versionId,
    void Function(double progress)? onProgress,
    bool resume = false,
  }) => _sendRawToFile(
    'GET',
    _fileContentPath(nodeId, versionId),
    destination,
    accessToken: accessToken,
    onResponseProgress: onProgress,
    resumeEntityTag: resume && versionId != null ? '"$versionId"' : null,
  );

  String _fileContentPath(String nodeId, String? versionId) {
    final path = '/api/v1/files/$nodeId/content';
    if (versionId == null) return path;
    return Uri(
      path: path,
      queryParameters: {'versionId': versionId},
    ).toString();
  }

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
            createdAt: e['createdAt'] == null
                ? null
                : DateTime.parse(e['createdAt'] as String),
            ciphertextSize: e['ciphertextSize'] as int?,
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
    metadataKeyScopeId: json['metadataKeyScopeId'] as String?,
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
          final identity = envelope['ownerIdentityPublicKey'] as String?;
          final signature = envelope['ownerSignature'] as String?;
          return FamilyShareEnvelope(
            targetDeviceId: envelope['targetDeviceId'] as String,
            keyVersion: envelope['keyVersion'] as int,
            ciphertext: base64Decode(envelope['ciphertext'] as String),
            ownerIdentityPublicKey: identity == null || identity.isEmpty
                ? null
                : base64Decode(identity),
            ownerSignature: signature == null || signature.isEmpty
                ? null
                : base64Decode(signature),
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
      ownerUsername: json['ownerUsername'] as String? ?? '',
      targetUsername: json['targetUsername'] as String? ?? '',
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
    int? maxResponseBytes,
  }) async {
    final response = await _openResponse(
      method,
      path,
      accessToken: accessToken,
      body: body,
      contentType: contentType,
    );
    final builder = BytesBuilder(copy: false);
    var received = 0;
    final total = response.contentLength;
    if (maxResponseBytes != null && total > maxResponseBytes) {
      final subscription = response.listen((_) {});
      await subscription.cancel();
      throw const FormatException(
        'Response exceeds the allowed in-memory size.',
      );
    }
    await for (final chunk in _withIdleTimeout(response)) {
      received += chunk.length;
      if (maxResponseBytes != null && received > maxResponseBytes) {
        throw const FormatException(
          'Response exceeds the allowed in-memory size.',
        );
      }
      builder.add(chunk);
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

  Future<HttpClientResponse> _openResponse(
    String method,
    String path, {
    String? accessToken,
    List<int>? body,
    String contentType = 'application/octet-stream',
    Map<String, String> headers = const {},
  }) async {
    try {
      // The TLS handshake happens during openUrl (connection setup), not
      // during close(), so badCertificateCallback rejections surface here —
      // both calls must be inside this try block.
      final request = await _transport.client
          .openUrl(method, _baseUrl.resolve(path))
          .timeout(_connectTimeout);
      if (accessToken != null) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
      }
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
        request.add(body);
      }
      try {
        return await request.close().timeout(_responseTimeout);
      } on TimeoutException {
        request.abort();
        rethrow;
      }
    } on HandshakeException {
      // Only a certificate that failed the pin is SERVER_IDENTITY_CHANGED
      // (spec §18), which must never be retried silently. Any other
      // handshake failure is an ordinary, retryable network error.
      if (_transport.identityRejected) {
        throw ServerIdentityMismatchException(_transport.pinnedFingerprint);
      }
      rethrow;
    }
  }

  /// Like [_sendRaw] but also returns the response headers, for endpoints
  /// that carry pagination cursors in them.
  Future<({Uint8List body, HttpHeaders headers})> _sendRawWithHeaders(
    String method,
    String path, {
    String? accessToken,
  }) async {
    final response = await _openResponse(
      method,
      path,
      accessToken: accessToken,
    );
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _withIdleTimeout(response)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return (body: bytes, headers: response.headers);
    }
    throw _errorFrom(
      response.statusCode,
      utf8.decode(bytes, allowMalformed: true),
    );
  }

  Stream<List<int>> _withIdleTimeout(Stream<List<int>> body) => body.timeout(
    _idleTimeout,
    onTimeout: (sink) {
      sink.addError(
        TimeoutException('The server stopped sending data.', _idleTimeout),
      );
      sink.close();
    },
  );

  Future<void> _sendRawToFile(
    String method,
    String path,
    File destination, {
    String? accessToken,
    void Function(double progress)? onResponseProgress,
    String? resumeEntityTag,
  }) async {
    const maxCiphertextBytes = 500 * 1024 * 1024 + 125 * 16;
    final resumable = resumeEntityTag != null;
    var offset = resumable && await destination.exists()
        ? await destination.length()
        : 0;
    final response = await _openResponse(
      method,
      path,
      accessToken: accessToken,
      headers: {
        if (offset > 0) HttpHeaders.rangeHeader: 'bytes=$offset-',
        if (offset > 0) HttpHeaders.ifRangeHeader: resumeEntityTag!,
      },
    );
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        offset > 0) {
      await response.drain<void>();
      // The partial file is already at least as long as the blob: it is
      // either complete or corrupt. Start over; AEAD and the plaintext
      // hash still verify whatever ends up on disk.
      await destination.delete();
      return _sendRawToFile(
        method,
        path,
        destination,
        accessToken: accessToken,
        onResponseProgress: onResponseProgress,
        resumeEntityTag: resumeEntityTag,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBytes = BytesBuilder(copy: false);
      await for (final chunk in _withIdleTimeout(response)) {
        if (errorBytes.length + chunk.length > 1024 * 1024) {
          throw _errorFrom(response.statusCode, '');
        }
        errorBytes.add(chunk);
      }
      throw _errorFrom(
        response.statusCode,
        utf8.decode(errorBytes.takeBytes(), allowMalformed: true),
      );
    }
    var total = response.contentLength;
    if (response.statusCode == HttpStatus.partialContent) {
      final range = _parseContentRange(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (range == null || range.start != offset) {
        await response.drain<void>();
        throw const FormatException(
          'The server returned an unexpected byte range.',
        );
      }
      total = range.total;
    } else {
      // A full body: the server ignored the range (the version changed,
      // or it does not support ranges), so discard any partial bytes.
      offset = 0;
    }
    if (total > maxCiphertextBytes) {
      final subscription = response.listen((_) {});
      await subscription.cancel();
      throw const FormatException(
        'Ciphertext download exceeds the HomeBox file limit.',
      );
    }

    await destination.parent.create(recursive: true);
    RandomAccessFile? output;
    var received = offset;
    try {
      output = await destination.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      if (total > 0) onResponseProgress?.call(received / total);
      await for (final chunk in _withIdleTimeout(response)) {
        received += chunk.length;
        if (received > maxCiphertextBytes) {
          throw const FormatException(
            'Ciphertext download exceeds the HomeBox file limit.',
          );
        }
        await output.writeFrom(chunk);
        if (total > 0) onResponseProgress?.call(received / total);
      }
      await output.flush();
      await output.close();
      output = null;
    } catch (e) {
      if (output != null) await output.close();
      // A resumable download keeps what it already received unless the
      // bytes themselves are wrong.
      if ((!resumable || e is FormatException) && await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    }
  }

  /// Parses `bytes <start>-<end>/<total>`; null for anything else.
  static ({int start, int total})? _parseContentRange(String? value) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value ?? '');
    if (match == null) return null;
    return (start: int.parse(match[1]!), total: int.parse(match[3]!));
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
    hasVaultKey: json['hasVaultKey'] as bool? ?? false,
    authentication: _deviceKeyAuthenticationFromJson(
      json,
      deviceKeyVersion: json['keyVersion'] as int,
    ),
  );

  static DeviceKeyAuthentication? _deviceKeyAuthenticationFromJson(
    Map<String, dynamic> json, {
    required int? deviceKeyVersion,
  }) {
    final signatureVersion = json['signatureVersion'];
    final accountPublicKey = json['accountIdentityPublicKey'];
    final signature = json['publicKeySignature'];
    if (signatureVersion == null &&
        accountPublicKey == null &&
        signature == null) {
      return null;
    }
    if (signatureVersion is! int ||
        deviceKeyVersion == null ||
        accountPublicKey is! String ||
        signature is! String) {
      throw const FormatException('Incomplete device key certificate.');
    }
    return DeviceKeyAuthentication(
      signatureVersion: signatureVersion,
      deviceKeyVersion: deviceKeyVersion,
      accountIdentityPublicKey: base64Decode(accountPublicKey),
      publicKeySignature: base64Decode(signature),
    );
  }
}
