// Constructor parameters below are named to give callers in other files
// readable arguments (`deviceIdentityStore:`) instead of the backing
// private field names.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/e2ee/device_identity.dart';
import '../../core/platform/client_platform.dart';
import '../../core/transport/homebox_api_client.dart';
import '../../core/transport/pinned_http_client.dart';
import '../../core/transport/pinned_server_store.dart';
import 'session_store.dart';

enum ServerConnectionStatus {
  /// No server has been pinned yet.
  disconnected,

  /// Contacting a candidate server to read its fingerprint (spec §15.3
  /// first-trust flow); nothing is trusted yet at this point.
  discovering,

  /// A fingerprint was discovered and is waiting for the user to confirm it
  /// out of band before it is pinned.
  awaitingTrust,

  /// A server is pinned but there is no active session.
  connectedLoggedOut,

  /// A login or silent refresh is in flight.
  authenticating,

  /// A valid session exists. Note this only proves server account identity
  /// (spec §16.1) — it does not by itself unlock the E2EE vault.
  authenticated,

  /// The last discovery or login attempt failed; see [errorMessage].
  failed,
}

/// Drives the "connect to a HomeBox server" flow end to end: fingerprint
/// discovery/pinning (ADR-009), login, silent session restore on startup via
/// the persisted refresh token, and logout. This intentionally does not
/// touch E2EE vault state — see [DeviceSetupController] for that — because
/// server login and E2EE provisioning are independent per ADR-012.
final class ServerConnectionController extends ChangeNotifier {
  ServerConnectionController({
    required DeviceIdentityStore deviceIdentityStore,
    PinnedServerStore? serverStore,
    SessionStore? sessionStore,
    Duration refreshBuffer = const Duration(seconds: 30),
  }) : _deviceIdentityStore = deviceIdentityStore,
       _serverStore = serverStore ?? PinnedServerStore(),
       _sessionStore = sessionStore ?? SessionStore(),
       _refreshBuffer = refreshBuffer;

  final DeviceIdentityStore _deviceIdentityStore;
  final PinnedServerStore _serverStore;
  final SessionStore _sessionStore;

  // How long before the access token's own expiry to proactively renew it.
  // Overridable only so tests can use a short-lived fake session without
  // waiting out a realistic `session_max_age` (15 minutes by default).
  final Duration _refreshBuffer;

  PinnedHttpClient? _transport;
  HomeBoxApiClient? _api;
  PinnedServer? _server;
  HomeBoxSession? _session;
  String? _pendingBaseUrl;
  String? _discoveredFingerprint;
  String? _errorMessage;
  String? _savedRefreshToken;
  Timer? _refreshTimer;
  Future<HomeBoxSession?>? _sessionRestoreInFlight;
  Future<bool>? _refreshInFlight;
  bool _disposed = false;

  ServerConnectionStatus _status = ServerConnectionStatus.disconnected;

  ServerConnectionStatus get status => _status;
  PinnedServer? get server => _server;
  HomeBoxSession? get session => _session;
  bool get hasSavedRefreshToken => _savedRefreshToken != null;
  String? get discoveredFingerprint => _discoveredFingerprint;
  String? get errorMessage => _errorMessage;

  /// The API client for the currently pinned server, or null before a
  /// server has been trusted (see [confirmTrust]). Available even before
  /// login succeeds, since some callers (none yet) might need unauthenticated
  /// calls; authenticated calls still need [session]'s access token.
  HomeBoxApiClient? get api => _api;

  Future<void> initialize() async {
    final saved = await _serverStore.load();
    if (saved == null) {
      _setStatus(ServerConnectionStatus.disconnected);
      return;
    }
    _connectTransport(saved);
    final refreshToken = await _sessionStore.loadRefreshToken();
    if (refreshToken == null) {
      _setStatus(ServerConnectionStatus.connectedLoggedOut);
      return;
    }
    _savedRefreshToken = refreshToken;
    _setStatus(ServerConnectionStatus.authenticating);
    await _restoreSavedSession();
  }

  /// Contacts [baseUrlText] and reads its identity fingerprint, without
  /// trusting it yet. The caller must show [discoveredFingerprint] to the
  /// user for out-of-band verification before calling [confirmTrust].
  Future<void> discover(String baseUrlText) async {
    _errorMessage = null;
    _setStatus(ServerConnectionStatus.discovering);
    try {
      final uri = _normalizeBaseUrl(baseUrlText);
      final fingerprint = await ServerDiscovery.probeFingerprint(
        uri.resolve('/health/live'),
      );
      _pendingBaseUrl = uri.toString();
      _discoveredFingerprint = fingerprint;
      _setStatus(ServerConnectionStatus.awaitingTrust);
    } catch (e) {
      _errorMessage = 'Could not reach that server: $e';
      _setStatus(ServerConnectionStatus.failed);
    }
  }

  /// Pins the fingerprint discovered by [discover]. Must only be called
  /// after the user has verified it out of band (ADR-009).
  Future<void> confirmTrust() async {
    final baseUrl = _pendingBaseUrl;
    final fingerprint = _discoveredFingerprint;
    if (baseUrl == null || fingerprint == null) return;
    final server = PinnedServer(baseUrl: baseUrl, fingerprint: fingerprint);
    await _serverStore.save(server);
    _connectTransport(server);
    _pendingBaseUrl = null;
    _discoveredFingerprint = null;
    _setStatus(ServerConnectionStatus.connectedLoggedOut);
  }

  void cancelTrust() {
    _pendingBaseUrl = null;
    _discoveredFingerprint = null;
    _setStatus(
      _server == null
          ? ServerConnectionStatus.disconnected
          : ServerConnectionStatus.connectedLoggedOut,
    );
  }

  Future<void> login(String username, String password) async {
    final api = _api;
    if (api == null) return;
    _errorMessage = null;
    _setStatus(ServerConnectionStatus.authenticating);
    DeviceIdentity? identity;
    try {
      identity = await _deviceIdentityStore.loadOrCreate();
      final session = await api.login(
        username: username,
        password: password,
        device: DeviceRegistration(
          id: await _sessionStore.loadOrCreateDeviceId(),
          name: _localDeviceName(),
          platform: homeBoxDevicePlatform,
          publicKey: Uint8List.fromList(identity.publicKey.bytes),
          keyVersion: 1,
        ),
      );
      _session = session;
      _savedRefreshToken = session.refreshToken;
      await _sessionStore.saveRefreshToken(session.refreshToken);
      _setStatus(ServerConnectionStatus.authenticated);
      _scheduleAccessTokenRefresh();
    } on HomeBoxApiException catch (e) {
      _errorMessage = e.message;
      _setStatus(ServerConnectionStatus.connectedLoggedOut);
    } on Exception catch (e) {
      _errorMessage = 'Login failed: $e';
      _setStatus(ServerConnectionStatus.connectedLoggedOut);
    } finally {
      identity?.destroy();
    }
  }

  Future<void> logout() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final api = _api;
    final session = _session;
    if (api != null && session != null) {
      try {
        await api.logout(session.refreshToken);
      } on Exception {
        // Best-effort: the local session is cleared regardless so the UI
        // never gets stuck showing a session the user asked to end.
      }
    }
    _session = null;
    _savedRefreshToken = null;
    await _sessionStore.clearRefreshToken();
    _setStatus(
      _server == null
          ? ServerConnectionStatus.disconnected
          : ServerConnectionStatus.connectedLoggedOut,
    );
  }

  /// Renews the access token shortly before it expires (`session_max_age`,
  /// 15 minutes by default) so an open Files/Sync session left idle for a
  /// while never hits a stale-token 401 mid-operation — previously nothing
  /// refreshed it again after the initial login/[initialize], so every
  /// authenticated call started failing once that lifetime elapsed.
  void _scheduleAccessTokenRefresh() {
    _refreshTimer?.cancel();
    final session = _session;
    if (session == null) return;
    final delay = session.accessTokenExpiresAt
        .subtract(_refreshBuffer)
        .difference(DateTime.now().toUtc());
    // A non-positive delay only happens with significant clock skew (or a
    // test fixture using an unrelated fixed timestamp); skip scheduling
    // rather than refreshing in a tight loop. The next authenticated call
    // simply hits a normal 401 in that unlikely case, same as before.
    if (delay <= Duration.zero) return;
    _refreshTimer = Timer(delay, () => unawaited(_refreshAccessToken()));
  }

  /// Returns the current session with a not-about-to-expire access token,
  /// refreshing first if needed — every authenticated caller (SyncEngine,
  /// FilesController, etc.) should read the session through this instead
  /// of [session] directly. This is necessary in addition to the proactive
  /// [_scheduleAccessTokenRefresh] timer above: mobile OSes routinely
  /// suspend or heavily throttle a backgrounded app's Dart timers, so a
  /// purely timer-driven refresh does not reliably fire while HomeBox sits
  /// in the background — the access token can still be stale by the time
  /// the user returns and the next sync/upload runs, surfacing as a
  /// stale-token 401 (`AUTH_TOKEN_EXPIRED`). This lazy, at-point-of-use
  /// check is what actually guarantees freshness regardless of how long
  /// the app was backgrounded, or of whether its timer fired at all.
  ///
  /// Tries at most twice: [_refreshAccessToken] shares one in-flight
  /// refresh across every concurrent caller, so if the session changed out
  /// from under an already-in-flight refresh (a logout/login racing with
  /// it), that shared refresh's result gets discarded for belonging to the
  /// old session and the still-stale current session is left untouched.
  /// The second attempt catches that case by actually starting a fresh
  /// refresh for the session that is current by then, rather than handing
  /// back a session this method never actually verified was fresh.
  Future<HomeBoxSession?> ensureFreshSession() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final current = _session;
      if (current == null) return _restoreSavedSession();
      final expiringSoon = current.accessTokenExpiresAt
          .subtract(_refreshBuffer)
          .isBefore(DateTime.now().toUtc());
      if (!expiringSoon) return current;
      if (!await _refreshAccessToken()) return null;
    }
    return _session;
  }

  /// Shares one in-flight refresh across concurrent callers (the
  /// background timer and any number of [ensureFreshSession] callers can
  /// all land here around the same time) rather than firing several
  /// redundant `/auth/refresh` requests with the same refresh token.
  Future<bool> _refreshAccessToken() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    return _refreshInFlight = _doRefreshAccessToken();
  }

  Future<bool> _doRefreshAccessToken() async {
    final api = _api;
    // Captured up front and compared by identity after the await: if the
    // user logs out (or another refresh/login already replaced the
    // session) while this HTTP call is in flight, _session will no longer
    // be this exact object, and the now-stale result below must be
    // discarded rather than resurrecting a session the user just left.
    final startedWithSession = _session;
    if (_disposed || api == null || startedWithSession == null) return false;
    try {
      final refreshed = await api.refresh(startedWithSession.refreshToken);
      if (_disposed || !identical(_session, startedWithSession)) return false;
      _session = refreshed;
      _savedRefreshToken = refreshed.refreshToken;
      await _sessionStore.saveRefreshToken(refreshed.refreshToken);
      notifyListeners();
      _scheduleAccessTokenRefresh();
      return true;
    } catch (e) {
      if (_disposed || !identical(_session, startedWithSession)) return false;
      if (_isInvalidRefreshTokenError(e)) {
        _session = null;
        _savedRefreshToken = null;
        await _sessionStore.clearRefreshToken();
        _setStatus(ServerConnectionStatus.connectedLoggedOut);
      } else {
        // Preserve the durable token and current UI session. The next
        // authenticated operation retries refresh instead of forcing login.
        _errorMessage = 'Could not refresh the saved session: $e';
        notifyListeners();
      }
      return false;
    } finally {
      _refreshInFlight = null;
    }
  }

  /// Retries a startup refresh with the durable token. Keeping this separate
  /// from access-token renewal lets a temporary offline launch recover later
  /// without requiring the user to enter credentials again.
  Future<HomeBoxSession?> _restoreSavedSession() {
    final inFlight = _sessionRestoreInFlight;
    if (inFlight != null) return inFlight;
    return _sessionRestoreInFlight = _doRestoreSavedSession();
  }

  Future<HomeBoxSession?> _doRestoreSavedSession() async {
    final api = _api;
    final refreshToken = _savedRefreshToken;
    if (_disposed || api == null || refreshToken == null) return null;
    try {
      final restored = await api.refresh(refreshToken);
      if (_disposed || _savedRefreshToken != refreshToken) return _session;
      _session = restored;
      _savedRefreshToken = restored.refreshToken;
      await _sessionStore.saveRefreshToken(restored.refreshToken);
      _errorMessage = null;
      _setStatus(ServerConnectionStatus.authenticated);
      _scheduleAccessTokenRefresh();
      return restored;
    } catch (e) {
      if (_disposed || _savedRefreshToken != refreshToken) return _session;
      if (_isInvalidRefreshTokenError(e)) {
        _savedRefreshToken = null;
        await _sessionStore.clearRefreshToken();
        _setStatus(ServerConnectionStatus.connectedLoggedOut);
      } else {
        _errorMessage = 'Could not restore the saved session: $e';
        _setStatus(ServerConnectionStatus.failed);
      }
      return null;
    } finally {
      _sessionRestoreInFlight = null;
    }
  }

  bool _isInvalidRefreshTokenError(Object error) =>
      error is HomeBoxApiException &&
      (error.code == 'AUTH_TOKEN_EXPIRED' ||
          error.code == 'AUTH_INVALID_CREDENTIALS' ||
          error.code == 'AUTH_DEVICE_REVOKED' ||
          error.code == 'FORBIDDEN');

  Future<void> forgetServer() async {
    await logout();
    await _serverStore.clear();
    _server = null;
    _transport?.close();
    _transport = null;
    _api = null;
    _setStatus(ServerConnectionStatus.disconnected);
  }

  void _connectTransport(PinnedServer server) {
    _transport?.close();
    _server = server;
    _transport = PinnedHttpClient(server.fingerprint);
    _api = HomeBoxApiClient(
      baseUrl: Uri.parse(server.baseUrl),
      transport: _transport!,
    );
  }

  String _localDeviceName() {
    try {
      final hostname = Platform.localHostname;
      return hostname.isEmpty ? 'HomeBox device' : hostname;
    } on Exception {
      return 'HomeBox device';
    }
  }

  void _setStatus(ServerConnectionStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _transport?.close();
    super.dispose();
  }
}

Uri _normalizeBaseUrl(String text) {
  final trimmed = text.trim();
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.parse(withScheme);
  if (uri.host.isEmpty) {
    throw const FormatException('Enter a server address like host:8787.');
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : 8787,
  );
}
