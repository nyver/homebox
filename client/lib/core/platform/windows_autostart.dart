import 'package:flutter/services.dart';

final class WindowsAutostart {
  static const MethodChannel _channel = MethodChannel('homebox/windows');

  Future<bool?> enabled() async {
    try {
      return await _channel.invokeMethod<bool>('getAutostart');
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool?> setEnabled(bool enabled) async {
    try {
      return await _channel.invokeMethod<bool>('setAutostart', enabled);
    } on MissingPluginException {
      return null;
    }
  }
}
