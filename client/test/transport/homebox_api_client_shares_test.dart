import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/transport/homebox_api_client.dart';
import 'package:homebox_client/core/transport/pinned_http_client.dart';

import 'fixture_server.dart';

void main() {
  test(
    'Family Vault share transport preserves opaque device envelopes',
    () async {
      final share = <String, dynamic>{
        'id': 'share-1',
        'nodeId': 'folder-1',
        'ownerUserId': 'owner-1',
        'targetUserId': 'member-1',
        'permission': 'READ',
        'createdAt': '2026-01-01T00:00:00Z',
        'envelopes': [
          {
            'targetDeviceId': 'member-device-1',
            'keyVersion': 2,
            'ciphertext': base64Encode([0, 255, 4]),
          },
        ],
      };
      final server = await startFixtureServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        if (request.method == 'GET' &&
            request.uri.pathSegments.length == 5 &&
            request.uri.pathSegments[3] == 'member/with space' &&
            request.uri.pathSegments[4] == 'share-devices') {
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode([
                {
                  'id': 'member-device-1',
                  'platform': 'ANDROID',
                  'publicKey': base64Encode(List.filled(32, 9)),
                  'keyVersion': 2,
                },
              ]),
            );
        } else if (request.method == 'POST' &&
            request.uri.path == '/api/v1/shares') {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          expect(decoded['operationId'], 'operation-1');
          expect(decoded['permission'], 'READ');
          expect(decoded['envelopes'], [
            {
              'targetDeviceId': 'member-device-1',
              'keyVersion': 2,
              'ciphertext': base64Encode([0, 255, 4]),
            },
          ]);
          request.response
            ..statusCode = 201
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(share));
        } else if (request.method == 'GET' &&
            (request.uri.path == '/api/v1/shares/incoming' ||
                request.uri.path == '/api/v1/shares/outgoing')) {
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode([share]));
        } else if (request.method == 'DELETE' &&
            request.uri.path == '/api/v1/shares/share-1') {
          request.response.statusCode = 204;
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final transport = PinnedHttpClient(fixtureServerFingerprint);
      addTearDown(transport.close);
      final api = HomeBoxApiClient(
        baseUrl: Uri.parse('https://127.0.0.1:${server.port}'),
        transport: transport,
      );

      final devices = await api.listShareableDevices(
        'access-token',
        'member/with space',
      );
      expect(devices.single.platform, 'ANDROID');
      expect(devices.single.publicKey, List.filled(32, 9));

      final created = await api.createReadShare(
        'access-token',
        operationId: 'operation-1',
        nodeId: 'folder-1',
        targetUserId: 'member-1',
        envelopes: [
          FamilyShareEnvelope(
            targetDeviceId: 'member-device-1',
            keyVersion: 2,
            ciphertext: Uint8List.fromList([0, 255, 4]),
          ),
        ],
      );
      expect(created.permission, 'READ');
      expect(created.envelopes.single.ciphertext, [0, 255, 4]);

      expect(
        (await api.listIncomingShares('access-token')).single.id,
        'share-1',
      );
      expect(
        (await api.listOutgoingShares('access-token')).single.id,
        'share-1',
      );
      await api.revokeShare('access-token', 'share-1');
    },
  );
}
