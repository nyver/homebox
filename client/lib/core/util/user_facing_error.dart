import 'dart:io';

import '../transport/homebox_api_client.dart';
import '../transport/network_errors.dart';
import '../transport/pinned_http_client.dart';

/// Turns an exception raised by a HomeBox operation into a sentence that can
/// be shown to the user. Raw `toString()` output such as
/// `HomeBoxApiException(409 REVISION_CONFLICT): …` or a `SocketException`
/// dump explains nothing to a non-developer, so known failure kinds get a
/// plain description and a hint about what to do next.
String describeError(Object error) {
  if (error is ServerIdentityMismatchException) {
    return 'The server presented a different identity than the one you '
        'verified, so HomeBox refused to connect. Confirm the server '
        'fingerprint with its administrator before reconnecting.';
  }
  if (isTransientNetworkError(error)) {
    return 'Cannot reach the HomeBox server. Check the network and try again.';
  }
  if (error is HomeBoxApiException) return _describeApiError(error);
  if (error is FileSystemException) {
    final reason = error.osError?.message.trim();
    final path = error.path;
    final subject = path == null || path.isEmpty ? 'a local file' : '"$path"';
    return reason == null || reason.isEmpty
        ? 'Could not access $subject.'
        : 'Could not access $subject: $reason';
  }
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  if (error is ArgumentError) return '${error.message ?? 'Invalid input.'}';
  final text = '$error';
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}

String _describeApiError(HomeBoxApiException error) {
  final reference = error.requestId.isEmpty
      ? ''
      : ' (reference ${error.requestId})';
  return switch (error.code) {
    'AUTH_INVALID_CREDENTIALS' => 'Incorrect username or password.',
    'AUTH_RATE_LIMITED' =>
      'Too many failed sign-in attempts. Wait a minute and try again.',
    'AUTH_TOKEN_EXPIRED' => 'Your session has expired. Sign in again.',
    'AUTH_DEVICE_REVOKED' => 'This device was removed from your account. Sign in again to register it.',
    'REVISION_CONFLICT' =>
      'This item was changed on another device. Refresh and try again.',
    'NOT_FOUND' || 'UPLOAD_NOT_FOUND' =>
      'This item no longer exists on the server. Refresh to update the list.',
    'FORBIDDEN' => 'You do not have access to this item.',
    'UPLOAD_EXPIRED' ||
    'UPLOAD_CHUNK_INVALID' ||
    'UPLOAD_ID_CONFLICT' => 'The upload could not be completed. Try again.',
    'UPLOAD_LIMIT_REACHED' => 'Too many unfinished uploads from this device. Wait for them to finish and try again.',
    'SYNC_CURSOR_INVALID' =>
      'Sync state is out of date. HomeBox will resynchronize.',
    // Validation messages are written by the server for display.
    'VALIDATION_ERROR' => error.message,
    'INTERNAL_ERROR' => 'The server could not complete the request$reference.',
    _ => '${error.message}$reference',
  };
}
