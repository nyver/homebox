import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/transport/pinned_http_client.dart';

import 'fixture_server.dart';

void main() {
  test('accepts a connection whose certificate matches the pinned fingerprint', () async {
    final server = await startFixtureServer((request) {
      request.response
        ..statusCode = 200
        ..write('ok')
        ..close();
    });
    addTearDown(() => server.close(force: true));

    final client = PinnedHttpClient(fixtureServerFingerprint);
    addTearDown(client.close);
    final request = await client.client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'));
    final response = await request.close();
    expect(response.statusCode, 200);
  });

  test('rejects a connection whose certificate does not match the pinned fingerprint', () async {
    final server = await startFixtureServer((request) {
      request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final client = PinnedHttpClient('0' * 64);
    addTearDown(client.close);
    Future<void> attempt() async {
      final request = await client.client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'));
      await request.close();
    }

    await expectLater(attempt(), throwsA(isA<HandshakeException>()));
  });

  test('ServerDiscovery.probeFingerprint reads the real fixture fingerprint', () async {
    final server = await startFixtureServer((request) {
      request.response
        ..statusCode = 200
        ..close();
    });
    addTearDown(() => server.close(force: true));

    final fingerprint = await ServerDiscovery.probeFingerprint(Uri.parse('https://127.0.0.1:${server.port}/health/live'));
    expect(fingerprint, fixtureServerFingerprint);
  });
}
