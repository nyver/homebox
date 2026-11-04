import 'dart:async';
import 'dart:io';

import 'pinned_http_client.dart';

/// Whether [error] is an expected, retryable connectivity failure — offline
/// Wi-Fi, a dropped mobile connection, a stalled server, or a TLS handshake
/// that broke for a reason other than a pin mismatch. Callers keep their
/// durable state (outbox, session, partial download) and retry later
/// instead of presenting such failures as errors.
bool isTransientNetworkError(Object error) {
  if (error is ServerIdentityMismatchException) return false;
  return error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      error is TlsException;
}
