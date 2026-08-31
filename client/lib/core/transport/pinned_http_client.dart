import 'dart:io';

import 'server_fingerprint.dart';

/// Thrown when a server's certificate does not match the pinned fingerprint.
/// A caller must treat this as a hard failure (`SERVER_IDENTITY_CHANGED`,
/// spec §18) and never silently retry without the user re-verifying trust.
final class ServerIdentityMismatchException implements Exception {
  const ServerIdentityMismatchException(this.pinnedFingerprint);

  final String pinnedFingerprint;

  @override
  String toString() =>
      'ServerIdentityMismatchException: server certificate does not match the pinned fingerprint $pinnedFingerprint';
}

/// An `HttpClient` that trusts exactly one server identity, by SHA-256
/// fingerprint of its ECDSA P-256 public key, instead of a certificate
/// authority. This is the client-side half of ADR-008/ADR-009 and mirrors
/// `internal/securetransport.PinnedClientConfig` on the Go side: normal
/// certificate-chain/hostname validation is replaced by this check, not
/// skipped in favor of no check.
final class PinnedHttpClient {
  PinnedHttpClient(this.pinnedFingerprint) {
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..badCertificateCallback = _verify;
  }

  final String pinnedFingerprint;
  late final HttpClient _client;

  HttpClient get client => _client;

  bool _verify(X509Certificate cert, String host, int port) {
    final fingerprint = ServerFingerprint.fromCertificateDer(cert.der);
    return fingerprint != null && fingerprint == pinnedFingerprint;
  }

  void close({bool force = false}) => _client.close(force: force);
}

/// Thrown by [ServerDiscovery.probeFingerprint] when a server does not
/// present a usable identity certificate.
final class ServerDiscoveryException implements Exception {
  const ServerDiscoveryException(this.message);

  final String message;

  @override
  String toString() => 'ServerDiscoveryException: $message';
}

/// Discovers a server's identity fingerprint before it is trusted, for the
/// Trust-On-First-Use / manual-verification flow described in spec §15.3.
/// This never trusts any data returned by the server; it exists only to let
/// the UI show the user a fingerprint to confirm before [PinnedHttpClient]
/// is ever used for a real request.
final class ServerDiscovery {
  const ServerDiscovery._();

  static Future<String> probeFingerprint(Uri healthCheckUrl) async {
    String? seen;
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) {
        seen = ServerFingerprint.fromCertificateDer(cert.der);
        return true; // Accepted only to inspect the certificate; nothing here is trusted yet.
      };
    try {
      final request = await client.getUrl(healthCheckUrl);
      final response = await request.close();
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
    final fingerprint = seen;
    if (fingerprint == null) {
      throw const ServerDiscoveryException(
        'Server did not present a recognizable P-256 identity certificate.',
      );
    }
    return fingerprint;
  }
}
