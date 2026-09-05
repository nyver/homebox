// ignore_for_file: prefer_initializing_formals

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/account_identity.dart';
import '../../core/e2ee/device_identity.dart';
import '../../core/e2ee/device_provisioning.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../server/server_connection_controller.dart';

enum DeviceProvisioningStatus { idle, loading, awaitingApproval, ready, failed }

/// Coordinates trusted-device vault-key provisioning without handling any
/// plaintext file data. The server sees only the opaque device and vault IDs
/// plus a ciphertext envelope created by [DeviceProvisioningCipher].
final class DeviceProvisioningController extends ChangeNotifier {
  DeviceProvisioningController({
    required DeviceIdentityStore deviceIdentityStore,
    required VaultKeyStore vaultKeyStore,
    required ServerConnectionController serverConnection,
    DeviceProvisioningCipher? cipher,
  }) : _deviceIdentityStore = deviceIdentityStore,
       _vaultKeyStore = vaultKeyStore,
       _serverConnection = serverConnection,
       _cipher = cipher ?? DeviceProvisioningCipher();

  final DeviceIdentityStore _deviceIdentityStore;
  final VaultKeyStore _vaultKeyStore;
  final ServerConnectionController _serverConnection;
  final DeviceProvisioningCipher _cipher;

  DeviceProvisioningStatus _status = DeviceProvisioningStatus.idle;
  String? _errorMessage;
  bool _disposed = false;

  DeviceProvisioningStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get busy => _status == DeviceProvisioningStatus.loading;

  /// Lists this account's active (non-revoked) devices, most recently
  /// created first, so Settings can show every device alongside its real
  /// approval state (`HomeBoxDevice.hasVaultKey`) rather than only the ones
  /// already approved.
  Future<List<transport.HomeBoxDevice>> accountDevices() async {
    final context = await _requireSession();
    if (context == null) return const [];
    _errorMessage = null;
    _setStatus(DeviceProvisioningStatus.loading);
    try {
      final devices = await context.api.listDevices(context.accessToken);
      _setStatus(DeviceProvisioningStatus.idle);
      return devices
          .where((device) => !device.isRevoked)
          .toList(growable: false)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      _fail(e);
      return const [];
    }
  }

  /// Lists active devices that can receive an envelope. The current device
  /// is excluded because a device must never provision a key to itself.
  Future<List<transport.HomeBoxDevice>> availableRecipientDevices() async {
    final context = await _requireSession();
    if (context == null) return const [];
    _errorMessage = null;
    _setStatus(DeviceProvisioningStatus.loading);
    try {
      final devices = await context.api.listDevices(context.accessToken);
      _setStatus(DeviceProvisioningStatus.idle);
      return devices
          .where((device) => !device.isRevoked && device.id != context.deviceId)
          .toList(growable: false);
    } catch (e) {
      _fail(e);
      return const [];
    }
  }

  /// Wraps this device's Vault Key for [target] and sends only the resulting
  /// ciphertext to the server. The target must already have logged in once so
  /// its device-bound X25519 public key is registered there.
  Future<bool> provisionDevice(
    transport.HomeBoxDevice target, {
    required bool fingerprintVerified,
  }) async {
    final context = await _requireSession();
    if (context == null) return false;
    if (target.isRevoked || target.id == context.deviceId) {
      _fail(
        const FormatException('Select another active device to provision.'),
      );
      return false;
    }
    if (!fingerprintVerified) {
      _fail(
        const FormatException(
          'Compare the pairing fingerprint on both devices before approval.',
        ),
      );
      return false;
    }
    _errorMessage = null;
    _setStatus(DeviceProvisioningStatus.loading);
    Uint8List? vaultId;
    Uint8List? targetDeviceId;
    SecretKey? vaultKey;
    AccountIdentity? accountIdentity;
    try {
      vaultKey = await _vaultKeyStore.loadVaultKey();
      if (vaultKey == null) {
        throw StateError('This device does not have an unlocked vault key.');
      }
      accountIdentity = await AccountIdentity.derive(
        vaultKey: vaultKey,
        accountId: context.userId,
      );
      final existingAuthentication = target.authentication;
      if (existingAuthentication != null &&
          !await accountIdentity.verifyDevice(
            certificate: _certificateFromTransport(existingAuthentication),
            accountId: context.userId,
            deviceId: target.id,
            devicePublicKey: target.publicKey,
          )) {
        throw const FormatException(
          'The server returned a device certificate that does not match this account identity.',
        );
      }
      final certificate = await accountIdentity.certifyDevice(
        accountId: context.userId,
        deviceId: target.id,
        deviceKeyVersion: target.keyVersion,
        devicePublicKey: target.publicKey,
      );
      final certificateBinding = await deviceCertificateBinding(certificate);
      vaultId = uuidStringToBytes(context.userId);
      targetDeviceId = uuidStringToBytes(target.id);
      final envelope = await _cipher.create(
        vaultKey: vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        vaultId: vaultId,
        recipientDeviceId: targetDeviceId,
        recipientPublicKey: SimplePublicKey(
          Uint8List.fromList(target.publicKey),
          type: KeyPairType.x25519,
        ),
        certificateBinding: certificateBinding,
      );
      await context.api.uploadKeyEnvelope(
        context.accessToken,
        targetDeviceId: target.id,
        vaultId: context.userId,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        ciphertext: envelope.encode(),
        deviceKeyAuthentication: _authenticationToTransport(certificate),
      );
      _setStatus(DeviceProvisioningStatus.ready);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    } finally {
      vaultId?.fillRange(0, vaultId.length, 0);
      targetDeviceId?.fillRange(0, targetDeviceId.length, 0);
      vaultKey?.destroy();
      accountIdentity?.destroy();
    }
  }

  /// Wraps this device's freshly created Vault Key for itself and uploads
  /// that as this device's own key envelope. Call this immediately after
  /// [VaultSetupController.createVault] succeeds on this device: the vault's
  /// creator never goes through [collectProvisioning] (there is no other
  /// trusted device yet to approve it), so without this it would otherwise
  /// be indistinguishable from a device still awaiting approval
  /// (`HomeBoxDevice.hasVaultKey` stays false) even though it is the vault's
  /// own root of trust.
  Future<bool> selfApprove() async {
    final context = await _requireSession();
    if (context == null) return false;
    _errorMessage = null;
    _setStatus(DeviceProvisioningStatus.loading);
    DeviceIdentity? identity;
    Uint8List? vaultId;
    Uint8List? deviceId;
    SecretKey? vaultKey;
    AccountIdentity? accountIdentity;
    try {
      identity = await _deviceIdentityStore.load();
      if (identity == null) {
        throw StateError('Prepare this device before creating a vault.');
      }
      vaultKey = await _vaultKeyStore.loadVaultKey();
      if (vaultKey == null) {
        throw StateError('This device does not have an unlocked vault key.');
      }
      accountIdentity = await AccountIdentity.derive(
        vaultKey: vaultKey,
        accountId: context.userId,
      );
      final certificate = await accountIdentity.certifyDevice(
        accountId: context.userId,
        deviceId: context.deviceId,
        deviceKeyVersion: homeBoxDeviceKeyVersion,
        devicePublicKey: identity.publicKey.bytes,
      );
      final certificateBinding = await deviceCertificateBinding(certificate);
      vaultId = uuidStringToBytes(context.userId);
      deviceId = uuidStringToBytes(context.deviceId);
      final envelope = await _cipher.create(
        vaultKey: vaultKey,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        vaultId: vaultId,
        recipientDeviceId: deviceId,
        recipientPublicKey: identity.publicKey,
        certificateBinding: certificateBinding,
      );
      await context.api.uploadKeyEnvelope(
        context.accessToken,
        targetDeviceId: context.deviceId,
        vaultId: context.userId,
        keyVersion: homeBoxPersonalVaultKeyVersion,
        ciphertext: envelope.encode(),
        deviceKeyAuthentication: _authenticationToTransport(certificate),
      );
      _setStatus(DeviceProvisioningStatus.ready);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    } finally {
      identity?.destroy();
      vaultId?.fillRange(0, vaultId.length, 0);
      deviceId?.fillRange(0, deviceId.length, 0);
      vaultKey?.destroy();
      accountIdentity?.destroy();
    }
  }

  /// Revokes [target]'s approval by ending its server session outright: its
  /// access and refresh tokens stop working immediately, so it must sign in
  /// and be approved again by a trusted device before it can rejoin the
  /// vault. This cannot retract a vault key [target] already decrypted and
  /// stored locally before revocation. Refuses to revoke the calling
  /// device's own session, which would otherwise lock this device out.
  Future<bool> revokeDevice(transport.HomeBoxDevice target) async {
    final context = await _requireSession();
    if (context == null) return false;
    if (target.id == context.deviceId) {
      _fail(
        const FormatException(
          'Sign out from this device instead of revoking it here.',
        ),
      );
      return false;
    }
    _errorMessage = null;
    _setStatus(DeviceProvisioningStatus.loading);
    try {
      await context.api.revokeDevice(context.accessToken, target.id);
      _setStatus(DeviceProvisioningStatus.idle);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// Checks whether a trusted device has approved this device, verifies the
  /// envelope's vault/device/key-version context, and persists the unwrapped
  /// Vault Key in OS-backed secure storage.
  Future<bool> collectProvisioning() async {
    final context = await _requireSession();
    if (context == null) return false;
    if (await _vaultKeyStore.exists()) {
      _fail(StateError('A vault already exists on this device.'));
      return false;
    }
    _errorMessage = null;
    _setStatus(DeviceProvisioningStatus.loading);
    DeviceIdentity? identity;
    Uint8List? vaultId;
    Uint8List? deviceId;
    SecretKey? vaultKey;
    AccountIdentity? accountIdentity;
    try {
      final stored = await context.api.downloadKeyEnvelope(
        context.accessToken,
        context.deviceId,
      );
      if (stored.vaultId != context.userId ||
          stored.keyVersion != homeBoxPersonalVaultKeyVersion) {
        throw const FormatException(
          'This provisioning envelope is for a different vault.',
        );
      }
      final envelope = DeviceProvisioningEnvelope.decode(stored.ciphertext);
      if (envelope.keyVersion != stored.keyVersion) {
        throw const FormatException(
          'Provisioning envelope key version does not match.',
        );
      }
      identity = await _deviceIdentityStore.load();
      if (identity == null) {
        throw StateError('Prepare this device before collecting approval.');
      }
      vaultId = uuidStringToBytes(context.userId);
      deviceId = uuidStringToBytes(context.deviceId);
      final authentication = stored.deviceKeyAuthentication;
      if (envelope.protocolVersion == homeBoxDeviceProvisioningVersion &&
          authentication == null) {
        throw const FormatException(
          'Provisioning v2 is missing its device key certificate.',
        );
      }
      final certificate = authentication == null
          ? null
          : _certificateFromTransport(authentication);
      final certificateBinding =
          certificate == null ||
              envelope.protocolVersion == homeBoxLegacyDeviceProvisioningVersion
          ? null
          : await deviceCertificateBinding(certificate);
      vaultKey = await _cipher.open(
        envelope: envelope,
        recipientKeyPair: identity.keyPair,
        vaultId: vaultId,
        recipientDeviceId: deviceId,
        certificateBinding: certificateBinding,
      );
      if (certificate != null) {
        accountIdentity = await AccountIdentity.derive(
          vaultKey: vaultKey,
          accountId: context.userId,
        );
        final valid = await accountIdentity.verifyDevice(
          certificate: certificate,
          accountId: context.userId,
          deviceId: context.deviceId,
          devicePublicKey: identity.publicKey.bytes,
        );
        if (!valid) {
          throw const FormatException(
            'The device key certificate is invalid. The server may have substituted a device key.',
          );
        }
      }
      await _vaultKeyStore.saveProvisionedVaultKey(vaultKey);
      _setStatus(DeviceProvisioningStatus.ready);
      return true;
    } on transport.HomeBoxApiException catch (e) {
      if (e.code == 'NOT_FOUND') {
        _errorMessage = null;
        _setStatus(DeviceProvisioningStatus.awaitingApproval);
        return false;
      }
      _fail(e);
      return false;
    } catch (e) {
      _fail(e);
      return false;
    } finally {
      identity?.destroy();
      vaultId?.fillRange(0, vaultId.length, 0);
      deviceId?.fillRange(0, deviceId.length, 0);
      vaultKey?.destroy();
      accountIdentity?.destroy();
    }
  }

  Future<_ProvisioningContext?> _requireSession() async {
    final api = _serverConnection.api;
    // Not _serverConnection.session directly — see FilesController's
    // _requireContext for why (mobile OSes suspend background timers).
    final session = await _serverConnection.ensureFreshSession();
    if (api == null || session == null) {
      _errorMessage = 'Connect and sign in before provisioning a device.';
      _setStatus(DeviceProvisioningStatus.failed);
      return null;
    }
    return _ProvisioningContext(
      api: api,
      accessToken: session.accessToken,
      userId: session.user.id,
      deviceId: session.device.id,
    );
  }

  void _fail(Object error) {
    _errorMessage = '$error';
    _setStatus(DeviceProvisioningStatus.failed);
  }

  void _setStatus(DeviceProvisioningStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

DeviceKeyCertificate _certificateFromTransport(
  transport.DeviceKeyAuthentication authentication,
) => DeviceKeyCertificate(
  signatureVersion: authentication.signatureVersion,
  deviceKeyVersion: authentication.deviceKeyVersion,
  accountIdentityPublicKey: authentication.accountIdentityPublicKey,
  signature: authentication.publicKeySignature,
);

transport.DeviceKeyAuthentication _authenticationToTransport(
  DeviceKeyCertificate certificate,
) => transport.DeviceKeyAuthentication(
  signatureVersion: certificate.signatureVersion,
  deviceKeyVersion: certificate.deviceKeyVersion,
  accountIdentityPublicKey: certificate.accountIdentityPublicKey,
  publicKeySignature: certificate.signature,
);

final class _ProvisioningContext {
  const _ProvisioningContext({
    required this.api,
    required this.accessToken,
    required this.userId,
    required this.deviceId,
  });

  final transport.HomeBoxApiClient api;
  final String accessToken;
  final String userId;
  final String deviceId;
}
