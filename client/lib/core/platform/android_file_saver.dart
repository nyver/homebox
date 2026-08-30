import 'package:flutter/services.dart';

/// `file_selector_android` has no `getSaveLocation` implementation (it only
/// supports opening files), so Android needs its own "Save As" boundary
/// instead of the `file_selector` one the other platforms share.
bool supportsAndroidSaveDialog(TargetPlatform platform) =>
    platform == TargetPlatform.android;

/// The platform boundary for letting the user choose where a decrypted
/// download is written on Android.
abstract interface class AndroidFileSaver {
  /// Prompts the user with the OS "Save As" dialog (defaulting to the
  /// Downloads folder) to choose a destination for the already-decrypted
  /// file at [sourcePath], suggesting [suggestedName]. Returns the display
  /// name of where it was saved, or null if the user cancelled.
  Future<String?> saveFile({
    required String sourcePath,
    required String suggestedName,
    String? mimeType,
  });
}

final class MethodChannelAndroidFileSaver implements AndroidFileSaver {
  MethodChannelAndroidFileSaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('homebox/file_save');

  final MethodChannel _channel;

  @override
  Future<String?> saveFile({
    required String sourcePath,
    required String suggestedName,
    String? mimeType,
  }) => _channel.invokeMethod<String>('saveFile', {
    'sourcePath': sourcePath,
    'suggestedName': suggestedName,
    'mimeType': mimeType ?? 'application/octet-stream',
  });
}
