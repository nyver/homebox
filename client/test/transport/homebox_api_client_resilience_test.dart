import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/transport/homebox_api_client.dart';
import 'package:homebox_client/core/transport/network_errors.dart';
import 'package:homebox_client/core/transport/pinned_http_client.dart';

import 'fixture_server.dart';

const _nodeId = '11111111-1111-4111-8111-111111111111';
const _versionId = '22222222-2222-4222-8222-222222222222';
const _blob = '0123456789';

HomeBoxApiClient _client(HttpServer server) {
  final transport = PinnedHttpClient(fixtureServerFingerprint);
  addTearDown(transport.close);
  return HomeBoxApiClient(
    baseUrl: Uri.parse('https://127.0.0.1:${server.port}'),
    transport: transport,
  );
}

Future<Directory> _tempDir() async {
  final dir = await Directory.systemTemp.createTemp('homebox_resume_test_');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

void main() {
  test(
    'a TLS failure that is not a pin mismatch stays a retryable network error',
    () async {
      // A plain TCP listener that closes immediately: the handshake fails
      // before any certificate is presented, as on a dropped connection.
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      listener.listen((socket) => socket.destroy());
      addTearDown(listener.close);
      final transport = PinnedHttpClient(fixtureServerFingerprint);
      addTearDown(transport.close);
      final api = HomeBoxApiClient(
        baseUrl: Uri.parse('https://127.0.0.1:${listener.port}'),
        transport: transport,
      );

      Object? failure;
      try {
        await api.me('token');
      } catch (e) {
        failure = e;
      }
      expect(failure, isNotNull);
      expect(failure, isNot(isA<ServerIdentityMismatchException>()));
      expect(isTransientNetworkError(failure!), isTrue, reason: '$failure');
    },
  );

  test(
    'an interrupted download resumes from the bytes already on disk',
    () async {
      final rangeHeaders = <String?>[];
      var requests = 0;
      final server = await startFixtureServer((request) async {
        requests++;
        rangeHeaders.add(request.headers.value(HttpHeaders.rangeHeader));
        if (requests == 1) {
          // Send the first four bytes, then drop the connection.
          request.response.contentLength = _blob.length;
          final socket = await request.response.detachSocket();
          socket.add(utf8.encode(_blob.substring(0, 4)));
          await socket.flush();
          socket.destroy();
          return;
        }
        expect(
          request.headers.value(HttpHeaders.ifRangeHeader),
          '"$_versionId"',
        );
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 4-9/10')
          ..contentLength = 6
          ..add(utf8.encode(_blob.substring(4)));
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final api = _client(server);
      final destination = File('${(await _tempDir()).path}/blob.part');

      await expectLater(
        api.downloadFileContentToFile(
          'token',
          _nodeId,
          destination,
          versionId: _versionId,
          resume: true,
        ),
        throwsA(predicate<Object>(isTransientNetworkError)),
      );
      expect(
        await destination.readAsString(),
        _blob.substring(0, 4),
        reason: 'received bytes are kept for the retry',
      );

      await api.downloadFileContentToFile(
        'token',
        _nodeId,
        destination,
        versionId: _versionId,
        resume: true,
      );
      expect(await destination.readAsString(), _blob);
      expect(rangeHeaders, [null, 'bytes=4-']);
    },
  );

  test(
    'a full response to a resumed request replaces the stale partial file',
    () async {
      final server = await startFixtureServer((request) async {
        // The version changed: the server ignores the range.
        request.response
          ..contentLength = 3
          ..add(utf8.encode('new'));
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final api = _client(server);
      final destination = File('${(await _tempDir()).path}/blob.part');
      await destination.writeAsString('stale-bytes');

      await api.downloadFileContentToFile(
        'token',
        _nodeId,
        destination,
        versionId: _versionId,
        resume: true,
      );
      expect(await destination.readAsString(), 'new');
    },
  );

  test(
    'listChildren follows the pagination cursor until the last page',
    () async {
      final seenQueries = <Map<String, String>>[];
      final server = await startFixtureServer((request) async {
        seenQueries.add(request.uri.queryParameters);
        final after = request.uri.queryParameters['after'];
        final id = after == null
            ? '33333333-3333-4333-8333-333333333331'
            : '33333333-3333-4333-8333-333333333332';
        if (after == null) {
          request.response.headers.set('X-Next-After', 'cursor-1');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode([
            {
              'id': id,
              'nodeType': 'DIRECTORY',
              'metadataCiphertext': base64Encode([1]),
              'metadataKeyVersion': 1,
              'revision': 1,
              'createdAt': '2026-01-01T00:00:00Z',
              'updatedAt': '2026-01-01T00:00:00Z',
            },
          ]),
        );
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final nodes = await _client(server)
          .listChildren('token', ownedOnly: true);
      expect(nodes.map((n) => n.id), [
        '33333333-3333-4333-8333-333333333331',
        '33333333-3333-4333-8333-333333333332',
      ]);
      expect(seenQueries.first['ownedOnly'], 'true');
      expect(seenQueries.last['after'], 'cursor-1');
    },
  );
}
