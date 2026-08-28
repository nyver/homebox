import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/transport/homebox_api_client.dart';
import 'package:homebox_client/core/transport/pinned_http_client.dart';

import 'fixture_server.dart';

/// A minimal fake server covering just the node/upload/download/sync
/// surface, enough to prove HomeBoxApiClient's request/response wiring
/// end to end — including that binary ciphertext with byte values that are
/// not valid UTF-8 survives the PUT-chunk / GET-content round trip
/// unchanged, which a UTF-8 decode step anywhere in that path would break.
void main() {
  test('binary chunk upload and content download preserve non-UTF-8 bytes exactly', () async {
    final storedChunks = <int, Uint8List>{};
    final server = await startFixtureServer((request) async {
      if (request.method == 'PUT' && request.uri.path.contains('/chunks/')) {
        final chunkNo = int.parse(request.uri.pathSegments.last);
        final bytes = await _collectBytes(request);
        storedChunks[chunkNo] = bytes;
        request.response.statusCode = 204;
      } else if (request.method == 'GET' && request.uri.path.endsWith('/content')) {
        final all = <int>[];
        for (var i = 0; i < storedChunks.length; i++) {
          all.addAll(storedChunks[i]!);
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.binary
          ..add(all);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final transport = PinnedHttpClient(fixtureServerFingerprint);
    addTearDown(transport.close);
    final api = HomeBoxApiClient(baseUrl: Uri.parse('https://127.0.0.1:${server.port}'), transport: transport);

    // 0x00-0xFF including bytes that are invalid as standalone UTF-8
    // (e.g. 0xFF, 0xFE, lone continuation bytes) — this is what would
    // corrupt if any layer routed it through a UTF-8 decoder.
    final chunk0 = Uint8List.fromList(List<int>.generate(256, (i) => i));
    final chunk1 = Uint8List.fromList(List<int>.generate(256, (i) => 255 - i));

    await api.putUploadChunk('token', 'upload-1', 0, chunk0);
    await api.putUploadChunk('token', 'upload-1', 1, chunk1);

    final downloaded = await api.downloadFileContent('token', 'node-1');
    expect(downloaded, [...chunk0, ...chunk1]);
  });

  test('node/version/sync JSON responses parse into the expected model objects', () async {
    final server = await startFixtureServer((request) async {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/api/v1/nodes') {
        request.response
          ..statusCode = 201
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'id': 'node-1', 'parentId': null, 'nodeType': 'FILE',
            'metadataCiphertext': base64Encode(utf8.encode('meta')), 'metadataKeyVersion': 1,
            'currentVersionId': null, 'revision': 3,
            'createdAt': '2026-01-01T00:00:00Z', 'updatedAt': '2026-01-01T00:00:00Z', 'deletedAt': null,
          }));
      } else if (request.method == 'GET' && path == '/api/v1/files/node-1/versions') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([
            {
              'id': 'version-1', 'blobId': 'blob-1',
              'e2eeHeader': base64Encode([1, 2, 3]), 'wrappedFileKey': base64Encode([4, 5, 6]),
              'keyScopeId': 'scope-1', 'keyVersion': 1, 'revision': 4, 'chunkCount': 1,
            },
          ]));
      } else if (request.method == 'GET' && path == '/api/v1/sync/changes') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'changes': [
              {'revision': 4, 'nodeId': 'node-1', 'operation': 'CREATE', 'createdAt': '2026-01-01T00:00:00Z'},
            ],
            'nextAfter': 4,
            'hasMore': false,
          }));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final transport = PinnedHttpClient(fixtureServerFingerprint);
    addTearDown(transport.close);
    final api = HomeBoxApiClient(baseUrl: Uri.parse('https://127.0.0.1:${server.port}'), transport: transport);

    final node = await api.createNode(
      'token',
      id: 'node-1',
      operationId: 'op-1',
      nodeType: 'FILE',
      metadataCiphertext: Uint8List.fromList(utf8.encode('meta')),
      metadataKeyVersion: 1,
    );
    expect(node.id, 'node-1');
    expect(node.revision, 3);
    expect(utf8.decode(node.metadataCiphertext), 'meta');

    final versions = await api.listFileVersions('token', 'node-1');
    expect(versions, hasLength(1));
    expect(versions.single.wrappedFileKey, [4, 5, 6]);

    final page = await api.syncChanges('token');
    expect(page.changes, hasLength(1));
    expect(page.changes.single.operation, 'CREATE');
    expect(page.hasMore, isFalse);
  });
}

Future<Uint8List> _collectBytes(HttpRequest request) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
