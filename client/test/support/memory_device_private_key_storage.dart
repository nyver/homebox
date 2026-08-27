import 'package:homebox_client/core/e2ee/device_identity.dart';

final class MemoryDevicePrivateKeyStorage implements DevicePrivateKeyStorage {
  MemoryDevicePrivateKeyStorage({this.failReads = false});

  final bool failReads;
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (failReads) throw Exception('Secure storage unavailable.');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
