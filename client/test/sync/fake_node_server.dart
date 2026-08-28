import 'dart:convert';
import 'dart:io';

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
  int _revision = 0;

  /// When set, every node mutation fails with this HTTP status/code instead
  /// of succeeding — used to exercise SyncEngine's retry/failure handling.
  int? failMutationsWithStatus;
  String? failMutationsWithCode;

  Future<HttpServer> start() => startFixtureServer(_handle);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (method == 'POST' && path == '/api/v1/auth/login') {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      final deviceId = (body['device'] as Map<String, dynamic>)['id'] as String;
      _writeJson(request, 200, {
        'user': {'id': userId, 'username': 'admin', 'role': 'ADMIN'},
        'device': {'id': deviceId, 'platform': 'WINDOWS'},
        'accessToken': 'access-token',
        'accessTokenExpiresAt': '2026-01-01T00:15:00Z',
        'refreshToken': 'refresh-token',
        'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
      });
      return;
    }
    if (failMutationsWithStatus != null && method != 'GET') {
      _writeJson(request, failMutationsWithStatus!, {
        'error': {'code': failMutationsWithCode ?? 'INTERNAL_ERROR', 'message': 'forced failure', 'requestId': 'req'},
      });
      return;
    }
    if (method == 'POST' && path == '/api/v1/nodes') {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
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
      final parentId = request.uri.queryParameters['parentId'];
      final children = _nodes.values.where((n) => n['parentId'] == parentId && n['deletedAt'] == null).toList();
      _writeJson(request, 200, children);
      return;
    }
    if (method == 'GET' && path == '/api/v1/sync/changes') {
      final after = int.parse(request.uri.queryParameters['after'] ?? '0');
      final pageSize = int.tryParse(request.uri.queryParameters['pageSize'] ?? '') ?? 500;
      final page = _changes.where((c) => (c['revision'] as int) > after).take(pageSize).toList();
      final hasMore = _changes.where((c) => (c['revision'] as int) > after).length > page.length;
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
          'error': {'code': 'NOT_FOUND', 'message': 'not found', 'requestId': 'req'},
        });
      } else {
        _writeJson(request, 200, node);
      }
      return;
    }
    if (method == 'PATCH' && path.startsWith('/api/v1/nodes/')) {
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      if (node == null) {
        _writeJson(request, 404, {
          'error': {'code': 'NOT_FOUND', 'message': 'not found', 'requestId': 'req'},
        });
        return;
      }
      if (node['revision'] != body['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {'code': 'REVISION_CONFLICT', 'message': 'stale revision', 'requestId': 'req'},
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
      final id = path.substring('/api/v1/nodes/'.length);
      final node = _nodes[id];
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      if (node == null) {
        _writeJson(request, 404, {
          'error': {'code': 'NOT_FOUND', 'message': 'not found', 'requestId': 'req'},
        });
        return;
      }
      if (node['revision'] != body['expectedRevision']) {
        _writeJson(request, 409, {
          'error': {'code': 'REVISION_CONFLICT', 'message': 'stale revision', 'requestId': 'req'},
        });
        return;
      }
      node['deletedAt'] = '2026-01-01T00:00:00Z';
      node['revision'] = _recordChange(id, 'DELETE');
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    if (method == 'POST' && path.endsWith('/restore')) {
      final id = path.substring('/api/v1/nodes/'.length, path.length - '/restore'.length);
      final node = _nodes[id];
      if (node == null) {
        _writeJson(request, 404, {
          'error': {'code': 'NOT_FOUND', 'message': 'not found', 'requestId': 'req'},
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
  Map<String, dynamic> remoteCreate({required String id, String? parentId, String nodeType = 'DIRECTORY', String metadataCiphertext = 'bQ==', int metadataKeyVersion = 1}) {
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
    _changes.add({'revision': _revision, 'nodeId': nodeId, 'operation': operation, 'createdAt': '2026-01-01T00:00:00Z'});
    return _revision;
  }

  void _writeJson(HttpRequest request, int status, Object body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    request.response.close();
  }
}
