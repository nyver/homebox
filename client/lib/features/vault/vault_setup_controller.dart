import 'package:flutter/foundation.dart';

import '../../core/e2ee/vault_key_store.dart';

enum VaultSetupStatus { checking, locked, creating, ready, failed }

/// Drives the "create this account's personal vault" flow — the missing
/// first-device bootstrap path described but not implemented by ADR-011/013
/// (see core/e2ee/vault_key_store.dart). This is deliberately independent
/// of [ServerConnectionController]/[DeviceSetupController]: server login
/// proves account identity, device setup creates this device's identity
/// key, and vault setup is the third, separate axis — none of the three
/// unlocks the others (ADR-012).
final class VaultSetupController extends ChangeNotifier {
  VaultSetupController(this._vaultKeyStore);

  final VaultKeyStore _vaultKeyStore;

  VaultSetupStatus _status = VaultSetupStatus.checking;
  String? _errorMessage;
  bool _disposed = false;

  VaultSetupStatus get status => _status;
  String? get errorMessage => _errorMessage;

  Future<void> initialize() async {
    _setStatus(VaultSetupStatus.checking);
    try {
      final exists = await _vaultKeyStore.exists();
      _setStatus(exists ? VaultSetupStatus.ready : VaultSetupStatus.locked);
    } catch (e) {
      // Broad on purpose: storage/decoding failures can throw
      // FormatException or ArgumentError, and the latter does not extend
      // Exception, so `on Exception` alone would miss it and crash.
      _errorMessage = '$e';
      _setStatus(VaultSetupStatus.failed);
    }
  }

  /// Creates the vault for [userId] (the authenticated account's opaque
  /// server ID) and returns the printable Recovery Secret for the caller to
  /// show the user exactly once. Returns null on failure; see
  /// [errorMessage].
  Future<String?> createVault(String userId) async {
    if (_status == VaultSetupStatus.creating || _status == VaultSetupStatus.ready) {
      return null;
    }
    _errorMessage = null;
    _setStatus(VaultSetupStatus.creating);
    try {
      final recoverySecret = await _vaultKeyStore.createVault(userId: userId);
      try {
        final exported = await recoverySecret.export();
        _setStatus(VaultSetupStatus.ready);
        return exported;
      } finally {
        recoverySecret.destroy();
      }
    } catch (e) {
      // Broad on purpose: VaultKeyStore.createVault throws StateError if a
      // vault already exists, which does not extend Exception.
      _errorMessage = '$e';
      _setStatus(VaultSetupStatus.locked);
      return null;
    }
  }

  void _setStatus(VaultSetupStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
