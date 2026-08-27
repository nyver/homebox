import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/device_identity.dart';

enum DeviceSetupStatus { checking, missing, creating, ready, failed }

final class DeviceSetupController extends ChangeNotifier {
  DeviceSetupController(this._identityStore);

  final DeviceIdentityStore _identityStore;

  DeviceSetupStatus _status = DeviceSetupStatus.checking;
  String? _publicKeyFingerprint;
  bool _disposed = false;

  DeviceSetupStatus get status => _status;
  String? get publicKeyFingerprint => _publicKeyFingerprint;

  Future<void> initialize() async {
    if (_status == DeviceSetupStatus.creating) return;
    _setStatus(DeviceSetupStatus.checking);
    DeviceIdentity? identity;
    try {
      identity = await _identityStore.load();
      if (identity == null) {
        _publicKeyFingerprint = null;
        _setStatus(DeviceSetupStatus.missing);
        return;
      }
      _publicKeyFingerprint = await _fingerprint(identity.publicKey.bytes);
      _setStatus(DeviceSetupStatus.ready);
    } on Exception {
      _publicKeyFingerprint = null;
      _setStatus(DeviceSetupStatus.failed);
    } finally {
      identity?.destroy();
    }
  }

  Future<void> prepareDevice() async {
    if (_status == DeviceSetupStatus.checking ||
        _status == DeviceSetupStatus.creating ||
        _status == DeviceSetupStatus.ready) {
      return;
    }
    _setStatus(DeviceSetupStatus.creating);
    DeviceIdentity? identity;
    try {
      identity = await _identityStore.loadOrCreate();
      _publicKeyFingerprint = await _fingerprint(identity.publicKey.bytes);
      _setStatus(DeviceSetupStatus.ready);
    } on Exception {
      _publicKeyFingerprint = null;
      _setStatus(DeviceSetupStatus.failed);
    } finally {
      identity?.destroy();
    }
  }

  Future<String> _fingerprint(List<int> publicKey) async {
    final digest = await Sha256().hash(publicKey);
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':')
        .toUpperCase();
  }

  void _setStatus(DeviceSetupStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
