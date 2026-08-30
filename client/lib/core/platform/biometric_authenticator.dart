import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Android is the only platform with an app-level biometric lock for now.
bool supportsBiometricAppLock(TargetPlatform platform) =>
    platform == TargetPlatform.android;

/// The platform boundary for unlocking HomeBox after it is opened or resumed.
abstract interface class BiometricAuthenticator {
  /// Returns whether the device has an enrolled biometric method available.
  Future<bool> isAvailable();

  /// Prompts the user for an enrolled biometric and reports whether it passed.
  Future<bool> authenticate();
}

final class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? localAuthentication})
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> isAvailable() async =>
      await _localAuthentication.isDeviceSupported() &&
      await _localAuthentication.canCheckBiometrics;

  @override
  Future<bool> authenticate() => _localAuthentication.authenticate(
    localizedReason: 'Unlock HomeBox to access your encrypted files.',
    options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
  );
}
