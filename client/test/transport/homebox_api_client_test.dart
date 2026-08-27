import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/transport/homebox_api_client.dart';
import 'package:homebox_client/core/transport/pinned_http_client.dart';

import 'fixture_server.dart';

void main() {
  group('HomeBoxApiClient', () {
    test('login parses a session response and sends the bearer token on later calls', () async {
      String? seenAuthorizationHeader;
      final server = await startFixtureServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        if (request.uri.path == '/api/v1/auth/login') {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          expect(decoded['username'], 'admin');
          expect(decoded['password'], 'correct horse battery staple');
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'user': {'id': 'user-1', 'username': 'admin', 'role': 'ADMIN'},
              'device': {'id': 'device-1', 'platform': 'WINDOWS'},
              'accessToken': 'test-access-token',
              'accessTokenExpiresAt': '2026-01-01T00:00:00Z',
              'refreshToken': 'test-refresh-token',
              'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
            }));
        } else if (request.uri.path == '/api/v1/users/me') {
          seenAuthorizationHeader = request.headers.value('authorization');
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'id': 'user-1', 'username': 'admin', 'role': 'ADMIN'}));
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final transport = PinnedHttpClient(fixtureServerFingerprint);
      addTearDown(transport.close);
      final api = HomeBoxApiClient(baseUrl: Uri.parse('https://127.0.0.1:${server.port}'), transport: transport);

      final session = await api.login(
        username: 'admin',
        password: 'correct horse battery staple',
        device: DeviceRegistration(
          id: 'device-1',
          name: 'Test Device',
          platform: 'WINDOWS',
          publicKey: Uint8List.fromList(List.filled(32, 7)),
          keyVersion: 1,
        ),
      );

      expect(session.user.username, 'admin');
      expect(session.device.id, 'device-1');
      expect(session.accessToken, 'test-access-token');

      final me = await api.me(session.accessToken);
      expect(me.username, 'admin');
      expect(seenAuthorizationHeader, 'Bearer test-access-token');
    });

    test('a spec §18 error envelope becomes a HomeBoxApiException with the same fields', () async {
      final server = await startFixtureServer((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = 401
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'error': {'code': 'AUTH_INVALID_CREDENTIALS', 'message': 'invalid username or password', 'requestId': 'req-1'},
          }));
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final transport = PinnedHttpClient(fixtureServerFingerprint);
      addTearDown(transport.close);
      final api = HomeBoxApiClient(baseUrl: Uri.parse('https://127.0.0.1:${server.port}'), transport: transport);

      try {
        await api.login(
          username: 'admin',
          password: 'wrong',
          device: DeviceRegistration(
            id: 'device-1',
            name: 'Test Device',
            platform: 'WINDOWS',
            publicKey: Uint8List.fromList(List.filled(32, 7)),
            keyVersion: 1,
          ),
        );
        fail('expected a HomeBoxApiException');
      } on HomeBoxApiException catch (e) {
        expect(e.statusCode, 401);
        expect(e.code, 'AUTH_INVALID_CREDENTIALS');
        expect(e.requestId, 'req-1');
      }
    });

    test('a mismatched server fingerprint surfaces as ServerIdentityMismatchException, not a generic network error', () async {
      final server = await startFixtureServer((request) async {
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final transport = PinnedHttpClient('0' * 64);
      addTearDown(transport.close);
      final api = HomeBoxApiClient(baseUrl: Uri.parse('https://127.0.0.1:${server.port}'), transport: transport);

      await expectLater(
        api.me('irrelevant-token'),
        throwsA(isA<ServerIdentityMismatchException>()),
      );
    });
  });
}
