import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../transport/fixture_server.dart';

/// A minimal fake HomeBox server: just enough of the login/refresh/logout
/// contract to drive [ServerConnectionController] end to end without
/// depending on the real Go binary being built.
final class _FakeHomeBoxServer {
  int _tokenCounter = 0;
  final Set<String> _validRefreshTokens = {};

  Future<HttpServer> start() => startFixtureServer(_handle);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    switch (request.uri.path) {
      case '/health/live':
        request.response.statusCode = 200;
      case '/api/v1/auth/login':
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        if (decoded['password'] != 'correct horse battery staple') {
          _writeError(request, 401, 'AUTH_INVALID_CREDENTIALS');
        } else {
          _writeSession(
            request,
            (decoded['device'] as Map<String, dynamic>)['id'] as String,
          );
        }
      case '/api/v1/auth/refresh':
        if (refreshDelay > Duration.zero) {
          await Future<void>.delayed(refreshDelay);
        }
        if (failRefreshTemporarily) {
          _writeError(request, 503, 'SERVER_UNAVAILABLE');
        } else {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          final refreshToken = decoded['refreshToken'] as String;
          if (!_validRefreshTokens.remove(refreshToken)) {
            _writeError(request, 401, 'AUTH_TOKEN_EXPIRED');
          } else {
            _writeSession(request, 'device-1');
          }
        }
      case '/api/v1/auth/logout':
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        _validRefreshTokens.remove(decoded['refreshToken'] as String);
        request.response.statusCode = 204;
      default:
        request.response.statusCode = 404;
    }
    await request.response.close();
  }

  /// How far past "now" each issued access token expires. A real value
  /// (rather than a fixed past timestamp) lets tests exercise
  /// [ServerConnectionController]'s proactive pre-expiry refresh.
  Duration accessTokenLifetime = const Duration(minutes: 15);

  /// Artificial delay before responding to `/api/v1/auth/refresh`, so a
  /// test can act (e.g. log out) while a refresh call is still in flight.
  Duration refreshDelay = Duration.zero;

  /// Makes a refresh fail without invalidating its token, as a flaky mobile
  /// network or temporarily unavailable server would.
  bool failRefreshTemporarily = false;

  void _writeSession(HttpRequest request, String deviceId) {
    final access = 'access-${_tokenCounter++}';
    final refresh = 'refresh-${_tokenCounter++}';
    _validRefreshTokens.add(refresh);
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'user': {'id': 'user-1', 'username': 'admin', 'role': 'ADMIN'},
          'device': {'id': deviceId, 'platform': 'WINDOWS'},
          'accessToken': access,
          'accessTokenExpiresAt': DateTime.now()
              .toUtc()
              .add(accessTokenLifetime)
              .toIso8601String(),
          'refreshToken': refresh,
          'refreshTokenExpiresAt': '2026-02-01T00:00:00Z',
        }),
      );
  }

  void _writeError(HttpRequest request, int status, String code) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'error': {'code': code, 'message': code, 'requestId': 'req'},
        }),
      );
  }
}

void main() {
  test(
    'discover -> confirmTrust -> login persists a pinned server and a session',
    () async {
      final fakeServer = _FakeHomeBoxServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));

      final serverStorage = MemoryPinnedServerStorage();
      final sessionStorage = MemorySessionStorage();
      final controller = ServerConnectionController(
        deviceIdentityStore: DeviceIdentityStore(
          MemoryDevicePrivateKeyStorage(),
        ),
        serverStore: PinnedServerStore(serverStorage),
        sessionStore: SessionStore(sessionStorage),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.status, ServerConnectionStatus.disconnected);

      await controller.discover('127.0.0.1:${httpServer.port}');
      expect(controller.status, ServerConnectionStatus.awaitingTrust);
      expect(controller.discoveredFingerprint, fixtureServerFingerprint);

      await controller.confirmTrust();
      expect(controller.status, ServerConnectionStatus.connectedLoggedOut);
      expect(serverStorage.values, isNotEmpty);

      await controller.login('admin', 'correct horse battery staple');
      expect(controller.status, ServerConnectionStatus.authenticated);
      expect(controller.session, isNotNull);
      expect(sessionStorage.values, isNotEmpty);
    },
  );

  test('a wrong password leaves the controller connected but logged out, with an error message', () async {
    final fakeServer = _FakeHomeBoxServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final controller = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
      sessionStore: SessionStore(MemorySessionStorage()),
    );
    addTearDown(controller.dispose);

    await controller.discover('127.0.0.1:${httpServer.port}');
    await controller.confirmTrust();
    await controller.login('admin', 'the wrong password');

    expect(controller.status, ServerConnectionStatus.connectedLoggedOut);
    expect(controller.errorMessage, isNotNull);
    expect(controller.session, isNull);
  });

  test('a fresh controller restores the session silently from the persisted refresh token', () async {
    final fakeServer = _FakeHomeBoxServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final serverStorage = MemoryPinnedServerStorage();
    final sessionStorage = MemorySessionStorage();
    final first = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(serverStorage),
      sessionStore: SessionStore(sessionStorage),
    );
    await first.discover('127.0.0.1:${httpServer.port}');
    await first.confirmTrust();
    await first.login('admin', 'correct horse battery staple');
    first.dispose();

    // Simulates an app restart: a brand-new controller sharing only the
    // persisted storage, not the in-memory state, of the first one.
    final second = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(serverStorage),
      sessionStore: SessionStore(sessionStorage),
    );
    addTearDown(second.dispose);
    await second.initialize();

    expect(second.status, ServerConnectionStatus.authenticated);
    expect(second.session, isNotNull);
  });

  test(
    'a temporary refresh failure preserves the saved mobile session for retry',
    () async {
      final fakeServer = _FakeHomeBoxServer();
      final httpServer = await fakeServer.start();
      addTearDown(() => httpServer.close(force: true));

      final serverStorage = MemoryPinnedServerStorage();
      final sessionStorage = MemorySessionStorage();
      final first = ServerConnectionController(
        deviceIdentityStore: DeviceIdentityStore(
          MemoryDevicePrivateKeyStorage(),
        ),
        serverStore: PinnedServerStore(serverStorage),
        sessionStore: SessionStore(sessionStorage),
      );
      await first.discover('127.0.0.1:${httpServer.port}');
      await first.confirmTrust();
      await first.login('admin', 'correct horse battery staple');
      first.dispose();

      fakeServer.failRefreshTemporarily = true;
      final restarted = ServerConnectionController(
        deviceIdentityStore: DeviceIdentityStore(
          MemoryDevicePrivateKeyStorage(),
        ),
        serverStore: PinnedServerStore(serverStorage),
        sessionStore: SessionStore(sessionStorage),
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();

      expect(restarted.status, ServerConnectionStatus.failed);
      expect(sessionStorage.values, isNotEmpty);

      fakeServer.failRefreshTemporarily = false;
      expect(await restarted.ensureFreshSession(), isNotNull);
      expect(restarted.status, ServerConnectionStatus.authenticated);
    },
  );

  test('the access token is proactively refreshed before it expires, so an idle session never surfaces a stale-token 401', () async {
    final fakeServer = _FakeHomeBoxServer()
      ..accessTokenLifetime = const Duration(milliseconds: 200);
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final controller = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
      sessionStore: SessionStore(MemorySessionStorage()),
      // Small enough that the 200ms access token lifetime above still
      // leaves a positive delay to schedule the background refresh timer.
      refreshBuffer: const Duration(milliseconds: 50),
    );
    addTearDown(controller.dispose);
    await controller.discover('127.0.0.1:${httpServer.port}');
    await controller.confirmTrust();
    await controller.login('admin', 'correct horse battery staple');
    final firstAccessToken = controller.session!.accessToken;

    // Past accessTokenLifetime - refreshBuffer, giving the scheduled
    // background refresh time to complete its own HTTP round trip.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(controller.status, ServerConnectionStatus.authenticated);
    expect(controller.session, isNotNull);
    expect(
      controller.session!.accessToken,
      isNot(firstAccessToken),
      reason: 'a new access token should have been fetched automatically',
    );
  });

  test('ensureFreshSession refreshes an expired token even if the proactive background timer never ran', () async {
    final fakeServer = _FakeHomeBoxServer()
      ..accessTokenLifetime = const Duration(milliseconds: 50);
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final controller = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
      sessionStore: SessionStore(MemorySessionStorage()),
      // Longer than the token's own lifetime, so _scheduleAccessTokenRefresh
      // computes a negative delay and skips scheduling entirely (see its
      // own "delay <= Duration.zero" guard) — simulating a mobile OS that
      // suspended the app's background Timer altogether while it sat
      // backgrounded, rather than merely running it late. ensureFreshSession
      // exists precisely to still recover in that case.
      refreshBuffer: const Duration(minutes: 5),
    );
    addTearDown(controller.dispose);
    await controller.discover('127.0.0.1:${httpServer.port}');
    await controller.confirmTrust();
    await controller.login('admin', 'correct horse battery staple');
    final firstAccessToken = controller.session!.accessToken;

    // Let the token's own short lifetime actually elapse.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final fresh = await controller.ensureFreshSession();

    expect(fresh, isNotNull);
    expect(
      fresh!.accessToken,
      isNot(firstAccessToken),
      reason:
          'this is the exact fix for "Sync error ... AUTH_TOKEN_EXPIRED" '
          'after reopening the Android app: the lazy check at the point of '
          'use must catch what the background timer missed',
    );
    expect(controller.status, ServerConnectionStatus.authenticated);
  });

  test('logging out while a proactive access-token refresh is in flight does not resurrect the session', () async {
    final fakeServer = _FakeHomeBoxServer()
      ..accessTokenLifetime = const Duration(milliseconds: 100)
      ..refreshDelay = const Duration(milliseconds: 300);
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final controller = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
      sessionStore: SessionStore(MemorySessionStorage()),
      refreshBuffer: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);
    await controller.discover('127.0.0.1:${httpServer.port}');
    await controller.confirmTrust();
    await controller.login('admin', 'correct horse battery staple');

    // Past accessTokenLifetime - refreshBuffer (80ms), so the background
    // refresh has started its HTTP call but not received the (300ms
    // delayed) response yet.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await controller.logout();

    // Give the delayed refresh response time to arrive after logout.
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(
      controller.session,
      isNull,
      reason:
          'a refresh that was already in flight when the user logged out '
          'must not resurrect the session once it completes',
    );
    expect(controller.status, ServerConnectionStatus.connectedLoggedOut);
  });

  test('logout clears the session but keeps the server pinned', () async {
    final fakeServer = _FakeHomeBoxServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final serverStorage = MemoryPinnedServerStorage();
    final controller = ServerConnectionController(
      deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
      serverStore: PinnedServerStore(serverStorage),
      sessionStore: SessionStore(MemorySessionStorage()),
    );
    addTearDown(controller.dispose);
    await controller.discover('127.0.0.1:${httpServer.port}');
    await controller.confirmTrust();
    await controller.login('admin', 'correct horse battery staple');

    await controller.logout();

    expect(controller.status, ServerConnectionStatus.connectedLoggedOut);
    expect(controller.session, isNull);
    expect(serverStorage.values, isNotEmpty);
  });
}
