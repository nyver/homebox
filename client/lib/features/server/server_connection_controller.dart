// Constructor parameters below are named to give callers in other files
// readable arguments (`deviceIdentityStore:`) instead of the backing
// private field names.
// ignore_for_file: prefer_initializing_formals
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/e2ee/device_identity.dart';
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
  }) : _deviceIdentityStore = deviceIdentityStore,
       _serverStore = serverStore ?? PinnedServerStore(),
       _sessionStore = sessionStore ?? SessionStore();

  final DeviceIdentityStore _deviceIdentityStore;
  final PinnedServerStore _serverStore;
  final SessionStore _sessionStore;

  PinnedHttpClient? _transport;
  HomeBoxApiClient? _api;
  PinnedServer? _server;
  HomeBoxSession? _session;
  String? _pendingBaseUrl;
  String? _discoveredFingerprint;
  String? _errorMessage;
  bool _disposed = false;

  ServerConnectionStatus _status = ServerConnectionStatus.disconnected;

  ServerConnectionStatus get status => _status;
  PinnedServer? get server => _server;
  HomeBoxSession? get session => _session;
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
    _setStatus(ServerConnectionStatus.authenticating);
    try {
      final session = await _api!.refresh(refreshToken);
      _session = session;
      await _sessionStore.saveRefreshToken(session.refreshToken);
      _setStatus(ServerConnectionStatus.authenticated);
    } catch (_) {
      // The refresh token may be expired, revoked, or the device may have
      // been removed server-side; fall back to requiring a fresh login
      // rather than surfacing this as a hard error on every startup.
      await _sessionStore.clearRefreshToken();
      _setStatus(ServerConnectionStatus.connectedLoggedOut);
    }
  }

  /// Contacts [baseUrlText] and reads its identity fingerprint, without
  /// trusting it yet. The caller must show [discoveredFingerprint] to the
  /// user for out-of-band verification before calling [confirmTrust].
  Future<void> discover(String baseUrlText) async {
    _errorMessage = null;
    _setStatus(ServerConnectionStatus.discovering);
    try {
      final uri = _normalizeBaseUrl(baseUrlText);
      final fingerprint = await ServerDiscovery.probeFingerprint(uri.resolve('/health/live'));
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
    _setStatus(_server == null ? ServerConnectionStatus.disconnected : ServerConnectionStatus.connectedLoggedOut);
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
          platform: 'WINDOWS',
          publicKey: Uint8List.fromList(identity.publicKey.bytes),
          keyVersion: 1,
        ),
      );
      _session = session;
      await _sessionStore.saveRefreshToken(session.refreshToken);
      _setStatus(ServerConnectionStatus.authenticated);
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
    await _sessionStore.clearRefreshToken();
    _setStatus(_server == null ? ServerConnectionStatus.disconnected : ServerConnectionStatus.connectedLoggedOut);
  }

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
    _api = HomeBoxApiClient(baseUrl: Uri.parse(server.baseUrl), transport: _transport!);
  }

  String _localDeviceName() {
    try {
      final hostname = Platform.localHostname;
      return hostname.isEmpty ? 'Windows Device' : hostname;
    } on Exception {
      return 'Windows Device';
    }
  }

  void _setStatus(ServerConnectionStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
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
  return Uri(scheme: 'https', host: uri.host, port: uri.hasPort ? uri.port : 8787);
}
