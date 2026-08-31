import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/transport/pinned_http_client.dart';
import 'package:homebox_client/core/transport/server_fingerprint.dart';

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

  test('fingerprint extraction rejects a P-256 point hidden outside SubjectPublicKeyInfo', () {
    final p256PrefixAndPoint = <int>[
      0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
      0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
      0x04,
      ...List<int>.generate(64, (index) => index + 1),
    ];
    final fakeRsaSpki = _der(0x30, [
      ..._der(0x30, const []),
      ..._der(0x03, const [0, 1]),
    ]);
    final tbs = _der(0x30, [
      ..._der(0xa0, _der(0x02, const [2])),
      ..._der(0x02, const [1]),
      ..._der(0x30, const []),
      ..._der(0x30, const []),
      ..._der(0x30, const []),
      ..._der(0x30, const []),
      ...fakeRsaSpki,
      ..._der(0xa3, p256PrefixAndPoint),
    ]);
    final certificate = _der(0x30, [
      ...tbs,
      ..._der(0x30, const []),
      ..._der(0x03, const [0, 1]),
    ]);

    expect(
      ServerFingerprint.fromCertificateDer(Uint8List.fromList(certificate)),
      isNull,
    );
  });
}

List<int> _der(int tag, List<int> content) {
  final length = content.length;
  final encodedLength = length < 128
      ? <int>[length]
      : <int>[0x82, length >> 8, length & 0xff];
  return <int>[tag, ...encodedLength, ...content];
}
