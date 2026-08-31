import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../transport/fixture_server.dart';

/// A minimal, stateful fake HomeBox server covering login + node CRUD +
/// the sync changes feed — exactly what SyncEngine drives. Deliberately
/// separate from files_controller_test.dart's fake server (which covers
/// upload/download instead): SyncEngine tests don't need file content, and
/// keeping each fake server narrow keeps its behavior easy to verify by
/// reading it.
final class FakeNodeServer {
  static const String userId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

  final Map<String, Map<String, dynamic>> _nodes = {};
  final List<Map<String, dynamic>> _changes = [];
  final Map<String, Map<String, dynamic>> _uploadSessions = {};
  final Map<String, List<Uint8List>> _uploadChunks = {};
  final Map<String, List<Map<String, dynamic>>> _fileVersions =
      {}; // by nodeId, newest first
  final Map<String, Uint8List> _blobs = {}; // by immutable fileVersionId
  int _revision = 0;
  String? _registeredDeviceId;

  /// When set, every node mutation fails with this HTTP status/code instead
  /// of succeeding — used to exercise SyncEngine's retry/failure handling.
  int? failMutationsWithStatus;
  String? failMutationsWithCode;

  /// Artificial delay before responding to a sync/changes pull, so a test
  /// can act (e.g. start a second runOnce()) while a pass is still in flight.
  Duration pullDelay = Duration.zero;

  /// Optional gate used to hold an in-flight content response while a test
  /// replaces or deletes the node in the local cache.
  Completer<void>? contentResponseGate;
  Completer<void>? contentRequestStarted;
  int contentDownloadCount = 0;
  int deleteRequestCount = 0;
  int ownedRootListRequestCount = 0;

  Future<HttpServer> start() => startFixtureServer(_handle);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (method == 'POST' && path == '/api/v1/auth/login') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final deviceId = (body['device'] as Map<String, dynamic>)['id'] as String;
      _registeredDeviceId = deviceId;
      _writeJson(request, 200, {
        'user': {'id': userId, 'username': 'admin', 'role': 'ADMIN'},
        'device': {'id': deviceId, 'platform': 'WINDOWS'},
        'accessToken': 'access-token',
        'accessTokenExpiresAt': _accessTokenExpiresAt(),
        'refreshToken': 'refresh-token',
        'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
      });
      return;
    }
    if (method == 'POST' && path == '/api/v1/auth/refresh') {
      // SyncEngine.ensureFreshSession() (via ServerConnectionController)
      // calls this whenever the access token looks expired or about to be;
      // a real value here (rather than nothing at all) keeps that check
      // from tearing down the session mid-test. Echoes the device actually
      // registered at login (like the real server would), not a hardcoded
      // placeholder.
      _writeJson(request, 200, {
        'user': {'id': userId, 'username': 'admin', 'role': 'ADMIN'},
        'device': {'id': _registeredDeviceId, 'platform': 'WINDOWS'},
        'accessToken': 'access-token',
        'accessTokenExpiresAt': _accessTokenExpiresAt(),
        'refreshToken': 'refresh-token',
        'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
      });
      return;
    }
    if (failMutationsWithStatus != null && method != 'GET') {
      _writeJson(request, failMutationsWithStatus!, {
        'error': {
          'code': failMutationsWithCode ?? 'INTERNAL_ERROR',
          'message': 'forced failure',
          'requestId': 'req',
        },
      });
      return;
    }
    if (method == 'POST' && path == '/api/v1/nodes') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final id = body['id'] as String;
      final node = _newNode(
        id: id,
        parentId: body['parentId'] as String?,
        nodeType: body['nodeType'] as String,
        metadataCiphertext: body['metadataCiphertext'] as String,
        metadataKeyVersion: body['metadataKeyVersion'] as int,
        revision: _recordChange(id, 'CREATE'),
      );
      _nodes[id] = node;
      _writeJson(request, 201, node);
      return;
    }
    if (method == 'GET' && path == '/api/v1/nodes/children') {
      if (request.uri.queryParameters['ownedOnly'] == 'true') {
        ownedRootListRequestCount++;
      }
      final parentId = request.uri.queryParameters['parentId'];
      final children = _nodes.values
          .where((n) => n['parentId'] == parentId && n['deletedAt'] == null)
          .toList();
      _writeJson(request, 200, children);
      return;
    }
    if (method == 'GET' && path == '/api/v1/sync/changes') {
      if (pullDelay > Duration.zero) await Future<void>.delayed(pullDelay);
      final after = int.parse(request.uri.queryParameters['after'] ?? '0');
      final pageSize =
          int.tryParse(request.uri.queryParameters['pageSize'] ?? '') ?? 500;
      final page = _changes
          .where((c) => (c['revision'] as int) > after)
          .take(pageSize)
          .toList();
      final hasMore =
          _changes.where((c) => (c['revision'] as int) > after).length >
          page.length;
      _writeJson(request, 200, {
        'changes': page,
        'nextAfter': page.isEmpty ? after : page.last['revision'],
        'hasMore': hasMore,
      });
      return;
    }
    if (method == 'GET' && path.startsWith('/api/v1/nodes/')) {
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      if (node == null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'not found',
            'requestId': 'req',
          },
        });
      } else {
        _writeJson(request, 200, node);
      }
      return;
    }
    if (method == 'PATCH' && path.startsWith('/api/v1/nodes/')) {
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      if (node == null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'not found',
            'requestId': 'req',
          },
        });
        return;
      }
      if (node['revision'] != body['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {
            'code': 'REVISION_CONFLICT',
            'message': 'stale revision',
            'requestId': 'req',
          },
        });
        return;
      }
      if (body['metadataCiphertext'] != null) {
        node['metadataCiphertext'] = body['metadataCiphertext'];
        node['metadataKeyVersion'] = body['metadataKeyVersion'];
      }
      if (body['moveParent'] == true) {
        node['parentId'] = body['parentId'];
      }
      node['revision'] = _recordChange(id, 'UPDATE');
      node['updatedAt'] = '2026-01-01T00:00:00Z';
      _writeJson(request, 200, node);
      return;
    }
    if (method == 'DELETE' && path.startsWith('/api/v1/nodes/')) {
      deleteRequestCount++;
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      if (node == null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'not found',
            'requestId': 'req',
          },
        });
        return;
      }
      if (node['revision'] != body['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {
            'code': 'REVISION_CONFLICT',
            'message': 'stale revision',
            'requestId': 'req',
          },
        });
        return;
      }
      node['deletedAt'] = '2026-01-01T00:00:00Z';
      node['revision'] = _recordChange(id, 'DELETE');
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    if (method == 'POST' && path == '/api/v1/uploads') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final uploadId = '${_nodes.length}-${_uploadSessions.length}-upload';
      _uploadSessions[uploadId] = body;
      _uploadChunks[uploadId] = List.filled(
        body['chunkCount'] as int,
        Uint8List(0),
      );
      _writeJson(request, 201, {
        'id': uploadId,
        'chunkCount': body['chunkCount'],
        'receivedChunks': <int>[],
      });
      return;
    }
    if (method == 'PUT' && path.contains('/chunks/')) {
      final segments = request.uri.pathSegments;
      final uploadId = segments[segments.length - 3];
      final chunkNo = int.parse(segments.last);
      _uploadChunks[uploadId]![chunkNo] = await _collectBytes(request);
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    if (method == 'POST' && path.endsWith('/complete')) {
      final uploadId =
          request.uri.pathSegments[request.uri.pathSegments.length - 2];
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final session = _uploadSessions[uploadId]!;
      final nodeId = session['targetNodeId'] as String;
      final node = _nodes[nodeId]!;
      if (node['revision'] != session['expectedRevision'] ||
          body['expectedRevision'] != session['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {
            'code': 'REVISION_CONFLICT',
            'message': 'stale revision',
            'requestId': 'req',
          },
        });
        return;
      }
      final fileVersionId = session['fileVersionId'] as String;
      final blobBuilder = BytesBuilder(copy: false);
      for (final chunk in _uploadChunks[uploadId]!) {
        blobBuilder.add(chunk);
      }
      _blobs[fileVersionId] = blobBuilder.takeBytes();
      final newRevision = _recordChange(nodeId, 'UPDATE');
      _fileVersions.putIfAbsent(nodeId, () => []).insert(0, {
        'id': fileVersionId,
        'blobId': session['blobId'],
        'e2eeHeader': session['e2eeHeader'],
        'wrappedFileKey': session['wrappedFileKey'],
        'keyScopeId': 'scope',
        'keyVersion': 1,
        'revision': newRevision,
        'chunkCount': session['chunkCount'],
      });
      node['currentVersionId'] = fileVersionId;
      node['metadataCiphertext'] = session['metadataCiphertext'];
      node['metadataKeyVersion'] = session['metadataKeyVersion'];
      node['revision'] = newRevision;
      node['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      _writeJson(request, 200, {
        'blobId': session['blobId'],
        'fileVersionId': fileVersionId,
        'revision': newRevision,
      });
      return;
    }
    if (method == 'GET' && path.endsWith('/versions')) {
      final nodeId =
          request.uri.pathSegments[request.uri.pathSegments.length - 2];
      _writeJson(request, 200, _fileVersions[nodeId] ?? <dynamic>[]);
      return;
    }
    if (method == 'GET' && path.endsWith('/content')) {
      final nodeId =
          request.uri.pathSegments[request.uri.pathSegments.length - 2];
      contentDownloadCount++;
      final started = contentRequestStarted;
      if (started != null && !started.isCompleted) started.complete();
      await contentResponseGate?.future;
      final versionId =
          request.uri.queryParameters['versionId'] ??
          _nodes[nodeId]?['currentVersionId'] as String?;
      final blob = _blobs[versionId];
      if (blob == null) {
        request.response.statusCode = 404;
        await request.response.close();
      } else {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.binary
          ..add(blob);
        await request.response.close();
      }
      return;
    }
    if (method == 'POST' && path.endsWith('/restore')) {
      final id = path.substring(
        '/api/v1/nodes/'.length,
        path.length - '/restore'.length,
      );
      final node = _nodes[id];
      if (node == null) {
        _writeJson(request, 404, {
          'error': {
            'code': 'NOT_FOUND',
            'message': 'not found',
            'requestId': 'req',
          },
        });
        return;
      }
      node['deletedAt'] = null;
      node['revision'] = _recordChange(id, 'RESTORE');
      _writeJson(request, 200, node);
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }

  /// Simulates a mutation made by a different device (e.g. a phone),
  /// bypassing the fake server's own HTTP layer entirely — the point is to
  /// give SyncEngine's *pull* path something to discover.
  Map<String, dynamic> remoteCreate({
    required String id,
    String? parentId,
    String nodeType = 'DIRECTORY',
    String metadataCiphertext = 'bQ==',
    int metadataKeyVersion = 1,
  }) {
    final node = _newNode(
      id: id,
      parentId: parentId,
      nodeType: nodeType,
      metadataCiphertext: metadataCiphertext,
      metadataKeyVersion: metadataKeyVersion,
      revision: _recordChange(id, 'CREATE'),
    );
    _nodes[id] = node;
    return node;
  }

  /// Flips a byte in [nodeId]'s stored ciphertext blob, simulating
  /// corruption or tampering — used to prove a caller skips re-downloading
  /// content it already has rather than to test the download path itself.
  void corruptBlob(String nodeId) {
    final versionId = _nodes[nodeId]!['currentVersionId'] as String;
    _blobs[versionId]![0] ^= 0xff;
  }

  Map<String, dynamic> _newNode({
    required String id,
    String? parentId,
    required String nodeType,
    required String metadataCiphertext,
    required int metadataKeyVersion,
    required int revision,
  }) {
    return {
      'id': id,
      'parentId': parentId,
      'nodeType': nodeType,
      'metadataCiphertext': metadataCiphertext,
      'metadataKeyVersion': metadataKeyVersion,
      'currentVersionId': null,
      'revision': revision,
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'deletedAt': null,
    };
  }

  int _recordChange(String nodeId, String operation) {
    _revision += 1;
    _changes.add({
      'revision': _revision,
      'nodeId': nodeId,
      'operation': operation,
      'createdAt': '2026-01-01T00:00:00Z',
    });
    return _revision;
  }

  /// A real near-future value (rather than a fixed past timestamp) so
  /// ServerConnectionController.ensureFreshSession() never sees this
  /// fixture's session as already expired.
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

Future<Uint8List> _collectBytes(HttpRequest request) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
