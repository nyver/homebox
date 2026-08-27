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
  const HomeBoxUser({required this.id, required this.username, required this.role});

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
    this.revokedAt,
  });

  final String id;
  final String name;
  final String platform;
  final Uint8List publicKey;
  final int keyVersion;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime? revokedAt;

  bool get isRevoked => revokedAt != null;
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
  const KeyEnvelope({required this.id, required this.vaultId, required this.keyVersion, required this.ciphertext});

  final String id;
  final String vaultId;
  final int keyVersion;
  final Uint8List ciphertext;
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
    final json = await _postJson('/api/v1/auth/login', body: {
      'username': username,
      'password': password,
      'device': device.toJson(),
    });
    return _sessionFromJson(json);
  }

  Future<HomeBoxSession> refresh(String refreshToken) async {
    final json = await _postJson('/api/v1/auth/refresh', body: {'refreshToken': refreshToken});
    return _sessionFromJson(json);
  }

  Future<void> logout(String refreshToken) =>
      _send('POST', '/api/v1/auth/logout', body: {'refreshToken': refreshToken});

  Future<HomeBoxUser> me(String accessToken) async {
    final json = await _getJson('/api/v1/users/me', accessToken: accessToken);
    return _userFromJson(json);
  }

  Future<List<HomeBoxDevice>> listDevices(String accessToken) async {
    final body = await _send('GET', '/api/v1/devices', accessToken: accessToken);
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded.map((entry) => _deviceFromJson(entry as Map<String, dynamic>)).toList(growable: false);
  }

  Future<void> revokeDevice(String accessToken, String deviceId) =>
      _send('DELETE', '/api/v1/devices/$deviceId', accessToken: accessToken);

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
    final json = await _postJson('/api/v1/devices/$targetDeviceId/key-envelope', accessToken: accessToken, body: {
      'vaultId': vaultId,
      'keyVersion': keyVersion,
      'ciphertext': base64Encode(ciphertext),
    });
    return json['id'] as String;
  }

  /// Downloads this device's own pending key envelope. The server only ever
  /// serves a device its own envelope (spec §16.2); [targetDeviceId] must be
  /// the caller's own device ID.
  Future<KeyEnvelope> downloadKeyEnvelope(String accessToken, String targetDeviceId) async {
    final json = await _getJson('/api/v1/devices/$targetDeviceId/key-envelope', accessToken: accessToken);
    return KeyEnvelope(
      id: json['id'] as String,
      vaultId: json['vaultId'] as String,
      keyVersion: json['keyVersion'] as int,
      ciphertext: base64Decode(json['ciphertext'] as String),
    );
  }

  Future<Map<String, dynamic>> _postJson(String path, {Map<String, dynamic>? body, String? accessToken}) async {
    final response = await _send('POST', path, accessToken: accessToken, body: body);
    return jsonDecode(response) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _getJson(String path, {String? accessToken}) async {
    final response = await _send('GET', path, accessToken: accessToken);
    return jsonDecode(response) as Map<String, dynamic>;
  }

  Future<String> _send(String method, String path, {String? accessToken, Map<String, dynamic>? body}) async {
    final HttpClientResponse response;
    try {
      // The TLS handshake happens during openUrl (connection setup), not
      // during close(), so badCertificateCallback rejections surface here —
      // both calls must be inside this try block.
      final request = await _transport.client.openUrl(method, _baseUrl.resolve(path));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      if (accessToken != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
      }
      if (body != null) {
        request.add(utf8.encode(jsonEncode(body)));
      }
      response = await request.close();
    } on HandshakeException {
      // badCertificateCallback rejected the server's certificate: either it
      // does not match the pinned fingerprint, or the handshake otherwise
      // failed. Either way this must not be treated as a retryable network
      // error (spec §18 SERVER_IDENTITY_CHANGED).
      throw ServerIdentityMismatchException(_transport.pinnedFingerprint);
    }
    final responseBody = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return responseBody;
    }
    throw _errorFrom(response.statusCode, responseBody);
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
      user: HomeBoxUser(id: user['id'] as String, username: user['username'] as String, role: user['role'] as String),
      device: HomeBoxDeviceRef(id: device['id'] as String, platform: device['platform'] as String),
      accessToken: json['accessToken'] as String,
      accessTokenExpiresAt: DateTime.parse(json['accessTokenExpiresAt'] as String),
      refreshToken: json['refreshToken'] as String,
      refreshTokenExpiresAt: DateTime.parse(json['refreshTokenExpiresAt'] as String),
    );
  }

  HomeBoxUser _userFromJson(Map<String, dynamic> json) =>
      HomeBoxUser(id: json['id'] as String, username: json['username'] as String, role: json['role'] as String);

  HomeBoxDevice _deviceFromJson(Map<String, dynamic> json) => HomeBoxDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String,
        publicKey: base64Decode(json['publicKey'] as String),
        keyVersion: json['keyVersion'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        lastSeenAt: DateTime.parse(json['lastSeenAt'] as String),
        revokedAt: json['revokedAt'] != null ? DateTime.parse(json['revokedAt'] as String) : null,
      );
}
