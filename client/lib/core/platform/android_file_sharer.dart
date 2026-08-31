import 'package:flutter/services.dart';

/// Whether the native Android share sheet is available for a Flutter target.
bool supportsAndroidFileSharing(TargetPlatform platform) =>
    platform == TargetPlatform.android;

/// The platform boundary for handing an already-decrypted temporary file to
/// another Android application through the system share sheet.
abstract interface class AndroidFileSharer {
  /// Opens the Android share sheet for [sourcePath]. The file must be inside
  /// HomeBox's dedicated cache directory; Android verifies that boundary
  /// again before issuing a read-only URI grant to the selected application.
  Future<void> shareFile({
    required String sourcePath,
    required String suggestedName,
    String? mimeType,
  });
}

final class MethodChannelAndroidFileSharer implements AndroidFileSharer {
  MethodChannelAndroidFileSharer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('homebox/file_share');

  final MethodChannel _channel;

  @override
  Future<void> shareFile({
    required String sourcePath,
    required String suggestedName,
    String? mimeType,
  }) => _channel.invokeMethod<void>('shareFile', {
    'sourcePath': sourcePath,
    'suggestedName': suggestedName,
    'mimeType': mimeType ?? 'application/octet-stream',
  });
}
