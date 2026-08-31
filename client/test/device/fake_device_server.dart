import 'dart:convert';
import 'dart:io';

import '../transport/fixture_server.dart';

/// A minimal, stateful fake HomeBox server covering login plus the account
/// device list/revoke endpoints. Deliberately separate from
/// sync/fake_node_server.dart (which only ever registers one device for one
/// SyncEngine under test): device-approval tests need several independent
/// devices signed in to the same account, which that fake's single
/// `_registeredDeviceId` field cannot represent.
final class FakeDeviceServer {
  static const String userId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

  final Map<String, Map<String, dynamic>> _devices = {};
  int revokeRequestCount = 0;
  final Set<String> uploadedEnvelopeTargetIds = {};

  Future<HttpServer> start() => startFixtureServer(_handle);

  /// Test-only shortcut for "a trusted device delivered this device a vault
  /// key envelope" — the actual envelope crypto is covered elsewhere
  /// (device_provisioning_test.dart) and by the Go backend's own
  /// hasVaultKey tests; this fake only needs to prove the controller reads
  /// and passes the flag through correctly.
  void setHasVaultKey(String deviceId, bool value) {
    _devices[deviceId]?['hasVaultKey'] = value;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (method == 'POST' && path == '/api/v1/auth/login') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final device = body['device'] as Map<String, dynamic>;
      final deviceId = device['id'] as String;
      _devices.putIfAbsent(
        deviceId,
        () => {
          'id': deviceId,
          'name': device['name'],
          'platform': device['platform'],
          'publicKey': device['publicKey'],
          'keyVersion': device['keyVersion'],
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
          'hasVaultKey': false,
        },
      );
      if (_devices[deviceId]!['revokedAt'] != null) {
        _writeJson(request, 403, {
          'error': {
            'code': 'FORBIDDEN',
            'message': 'device revoked',
            'requestId': 'req',
          },
        });
        return;
      }
      _writeJson(request, 200, {
        'user': {'id': userId, 'username': 'admin', 'role': 'ADMIN'},
        'device': {'id': deviceId, 'platform': device['platform']},
        'accessToken': 'access-token-$deviceId',
        'accessTokenExpiresAt': _accessTokenExpiresAt(),
        'refreshToken': 'refresh-token-$deviceId',
        'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
      });
      return;
    }
    if (method == 'POST' && path == '/api/v1/auth/refresh') {
      final deviceId = _deviceIdForToken(request);
      _writeJson(request, 200, {
        'user': {'id': userId, 'username': 'admin', 'role': 'ADMIN'},
        'device': {'id': deviceId, 'platform': _devices[deviceId]?['platform']},
        'accessToken': 'access-token-$deviceId',
        'accessTokenExpiresAt': _accessTokenExpiresAt(),
        'refreshToken': 'refresh-token-$deviceId',
        'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
      });
      return;
    }
    if (path.startsWith('/api/v1/devices') &&
        !_requireActiveCaller(request)) {
      return;
    }
    if (method == 'GET' && path == '/api/v1/devices') {
      final out = _devices.values
          .where((d) => d['revokedAt'] == null)
          .toList(growable: false);
      _writeJson(request, 200, out);
      return;
    }
    if (method == 'DELETE' && path.startsWith('/api/v1/devices/')) {
      revokeRequestCount++;
      final id = path.substring('/api/v1/devices/'.length);
      final device = _devices[id];
      if (device == null || device['revokedAt'] != null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'device not found',
            'requestId': 'req',
          },
        });
        return;
      }
      device['revokedAt'] = DateTime.now().toUtc().toIso8601String();
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    if (method == 'POST' && path.endsWith('/key-envelope')) {
      final id = path.substring(
        '/api/v1/devices/'.length,
        path.length - '/key-envelope'.length,
      );
      final device = _devices[id];
      if (device == null || device['revokedAt'] != null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'device not found',
            'requestId': 'req',
          },
        });
        return;
      }
      uploadedEnvelopeTargetIds.add(id);
      device['hasVaultKey'] = true;
      _writeJson(request, 201, {'id': 'envelope-$id'});
      return;
    }
    _writeJson(request, 404, {
      'error': {'code': 'NOT_FOUND', 'message': 'unhandled route', 'requestId': 'req'},
    });
  }

  String? _deviceIdForToken(HttpRequest request) {
    final header = request.headers.value('authorization') ?? '';
    const prefix = 'Bearer access-token-';
    if (!header.startsWith(prefix)) return null;
    return header.substring(prefix.length);
  }

  /// Mirrors the real server's `authenticated` middleware: a revoked
  /// device's access token must stop working immediately, not just its
  /// ability to log in again.
  bool _requireActiveCaller(HttpRequest request) {
    final callerId = _deviceIdForToken(request);
    final caller = callerId == null ? null : _devices[callerId];
    if (caller == null || caller['revokedAt'] != null) {
      _writeJson(request, 403, {
        'error': {
          'code': 'FORBIDDEN',
          'message': 'device revoked or unknown',
          'requestId': 'req',
        },
      });
      return false;
    }
    return true;
  }

  String _accessTokenExpiresAt() =>
      DateTime.now().toUtc().add(const Duration(minutes: 15)).toIso8601String();

  void _writeJson(HttpRequest request, int status, Object body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    request.response.close();
  }
}
