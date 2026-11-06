// ignore_for_file: prefer_initializing_formals

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/account_identity.dart';
import '../../core/e2ee/recovery.dart';
import '../../core/e2ee/recovery_bundle.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/user_facing_error.dart';
import '../server/server_connection_controller.dart';
import '../../core/localization/user_text.dart';

enum RecoveryBackupStatus {
  /// Not signed in, or this device has no unlocked vault yet.
  unknown,
  checking,

  /// The server holds a recovery bundle for this account.
  protected,

  /// The server has no recovery bundle and this device holds no Recovery
  /// Secret material to create one from; a new Recovery Secret is needed.
  unprotected,
  failed,
}

/// Keeps the account's recovery bundle on the server so a Recovery Secret
/// alone can restore the vault on a clean device (spec §10.12), and drives
/// that restore. The server only ever receives ciphertext plus an
/// account-identity signature; the Recovery Secret never leaves the client.
final class RecoveryController extends ChangeNotifier {
  RecoveryController({
    required VaultKeyStore vaultKeyStore,
    required ServerConnectionController serverConnection,
  }) : _vaultKeyStore = vaultKeyStore,
       _serverConnection = serverConnection;

  final VaultKeyStore _vaultKeyStore;
  final ServerConnectionController _serverConnection;

  RecoveryBackupStatus _status = RecoveryBackupStatus.unknown;
  String? _errorMessage;
  DateTime? _updatedAt;
  bool _busy = false;
  bool _disposed = false;

  RecoveryBackupStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// When the server's recovery bundle was last replaced.
  DateTime? get updatedAt => _updatedAt;

  /// True while a refresh, rotation, or restore is running.
  bool get busy => _busy;

  /// Checks whether the server holds this account's recovery bundle and, if
  /// not, uploads one sealed from this device's own Recovery Secret material.
  /// Vaults created before recovery bundles existed heal this way the first
  /// time their creating device opens Settings.
  Future<void> refresh() async {
    if (_busy) return;
    // Claimed before the first await so overlapping calls cannot both run.
    _busy = true;
    try {
      final api = _serverConnection.api;
      final session = await _serverConnection.ensureFreshSession();
      if (api == null || session == null || !await _vaultKeyStore.exists()) {
        _updatedAt = null;
        _setStatus(RecoveryBackupStatus.unknown);
        return;
      }
      _errorMessage = null;
      _setStatus(RecoveryBackupStatus.checking);
      final stored = await api.getRecoveryBundle(session.accessToken);
      if (stored != null) {
        _updatedAt = stored.updatedAt;
        _setStatus(RecoveryBackupStatus.protected);
        return;
      }
      final bundle = await _vaultKeyStore.sealRecoveryBundle(
        userId: session.user.id,
      );
      if (bundle == null) {
        _updatedAt = null;
        _setStatus(RecoveryBackupStatus.unprotected);
        return;
      }
      await _upload(api, session.accessToken, session.user.id, bundle);
      _updatedAt = DateTime.now().toUtc();
      _setStatus(RecoveryBackupStatus.protected);
    } catch (e) {
      _errorMessage = describeError(e);
      _setStatus(RecoveryBackupStatus.failed);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Issues a new Recovery Secret for this vault and replaces the server's
  /// bundle with one protected by it. Returns the printable secret for the
  /// caller to show exactly once, or null on failure (see [errorMessage]).
  ///
  /// The previous secret stops working against the server's current bundle,
  /// but anyone holding both it and an older server backup can still use
  /// that backup: the Vault Key itself does not change.
  Future<String?> createNewRecoverySecret() async {
    if (_busy) return null;
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    PreparedRecovery? prepared;
    try {
      final api = _serverConnection.api;
      final session = await _serverConnection.ensureFreshSession();
      if (api == null || session == null) {
        throw StateError(
          UserText.of(
            en: 'Sign in before creating a Recovery Secret.',
            ru: 'Войдите, прежде чем создавать Recovery Secret.',
          ),
        );
      }
      prepared = await _vaultKeyStore.prepareNewRecoverySecret(
        userId: session.user.id,
      );
      await _upload(api, session.accessToken, session.user.id, prepared.bundle);
      await _vaultKeyStore.savePreparedRecovery(prepared);
      final exported = await prepared.recoverySecret.export();
      _updatedAt = DateTime.now().toUtc();
      _status = RecoveryBackupStatus.protected;
      return exported;
    } catch (e) {
      _errorMessage = describeError(e);
      return null;
    } finally {
      prepared?.destroy();
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Restores the vault on this clean device from the server's recovery
  /// bundle and the user's [recoverySecretText]. Returns false and sets
  /// [errorMessage] on failure; nothing is stored unless the secret opens
  /// the bundle.
  Future<bool> restoreVault(String recoverySecretText) async {
    if (_busy) return false;
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    RecoverySecret? recoverySecret;
    try {
      final api = _serverConnection.api;
      final session = await _serverConnection.ensureFreshSession();
      if (api == null || session == null) {
        throw StateError(
          UserText.of(
            en: 'Sign in to the account you want to recover first.',
            ru: 'Сначала войдите в аккаунт, который нужно восстановить.',
          ),
        );
      }
      try {
        // Spaces and line breaks are ignored: the secret is shown in groups
        // and is often typed back from paper.
        recoverySecret = RecoverySecret.parse(
          recoverySecretText.replaceAll(RegExp(r'\s'), ''),
        );
      } on FormatException {
        throw FormatException(
          UserText.of(
            en: 'This is not a HomeBox Recovery Secret. It starts with HBXR1-.',
            ru: 'Это не Recovery Secret HomeBox. Он начинается с HBXR1-.',
          ),
        );
      }
      final stored = await api.getRecoveryBundle(session.accessToken);
      if (stored == null) {
        throw StateError(
          UserText.of(
            en:
                'The server has no recovery data for this account. Approve this '
                'device from another trusted device instead.',
            ru:
                'На сервере нет данных для восстановления этого аккаунта. '
                'Подтвердите устройство с другого доверенного устройства.',
          ),
        );
      }
      try {
        await _vaultKeyStore.restoreVaultFromRecovery(
          userId: session.user.id,
          recoverySecret: recoverySecret,
          bundle: RecoveryBundle.decode(stored.bundle),
        );
      } on SecretBoxAuthenticationError {
        throw StateError(
          UserText.of(
            en:
                'This Recovery Secret does not belong to this account, or it was '
                'replaced by a newer one.',
            ru: 'Этот Recovery Secret не относится к аккаунту или был заменён более новым.',
          ),
        );
      }
      _updatedAt = stored.updatedAt;
      _status = RecoveryBackupStatus.protected;
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      return false;
    } finally {
      recoverySecret?.destroy();
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _upload(
    transport.HomeBoxApiClient api,
    String accessToken,
    String userId,
    RecoveryBundle bundle,
  ) async {
    final vaultKey = await _vaultKeyStore.loadVaultKey();
    if (vaultKey == null) {
      throw StateError(
        UserText.of(
          en: 'This device does not have an unlocked vault key.',
          ru: 'На этом устройстве нет разблокированного ключа хранилища.',
        ),
      );
    }
    AccountIdentity? identity;
    try {
      identity = await AccountIdentity.derive(
        vaultKey: vaultKey,
        accountId: userId,
      );
      final encoded = bundle.encode();
      final signature = await identity.signRecoveryBundle(
        accountId: userId,
        bundle: encoded,
      );
      await api.putRecoveryBundle(
        accessToken,
        bundle: encoded,
        accountIdentityPublicKey: Uint8List.fromList(identity.publicKey.bytes),
        signature: signature,
      );
    } finally {
      identity?.destroy();
      vaultKey.destroy();
    }
  }

  void _setStatus(RecoveryBackupStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
