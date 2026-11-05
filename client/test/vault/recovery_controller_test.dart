import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/e2ee/account_identity.dart';
import 'package:homebox_client/core/e2ee/device_identity.dart';
import 'package:homebox_client/core/e2ee/vault_key_store.dart';
import 'package:homebox_client/core/transport/pinned_server_store.dart';
import 'package:homebox_client/features/server/server_connection_controller.dart';
import 'package:homebox_client/features/server/session_store.dart';
import 'package:homebox_client/features/vault/recovery_controller.dart';

import '../support/memory_device_private_key_storage.dart';
import '../support/memory_pinned_server_storage.dart';
import '../support/memory_session_storage.dart';
import '../support/memory_vault_key_storage.dart';
import '../transport/fixture_server.dart';

/// Covers login plus the recovery-bundle endpoints. Like the real server,
/// it refuses a bundle whose account-identity signature does not verify, so
/// these tests also prove the client signs exactly what it uploads.
final class _FakeRecoveryServer {
  static const String userId = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

  String? bundle;
  List<int>? accountIdentityPublicKey;
  int uploads = 0;

  Future<HttpServer> start() => startFixtureServer(_handle);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (method == 'POST' &&
        (path == '/api/v1/auth/login' || path == '/api/v1/auth/refresh')) {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final device = body['device'] as Map<String, dynamic>?;
      _writeJson(request, 200, {
        'user': {'id': userId, 'username': 'admin', 'role': 'ADMIN'},
        'device': {'id': device?['id'] ?? 'unused', 'platform': 'WINDOWS'},
        'accessToken': 'access-token',
        'accessTokenExpiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 15))
            .toIso8601String(),
        'refreshToken': 'refresh-token',
        'refreshTokenExpiresAt': '2099-01-01T00:00:00Z',
      });
    } else if (path == '/api/v1/users/me/recovery' && method == 'GET') {
      if (bundle == null) {
        _writeJson(request, 404, {
          'error': {'code': 'NOT_FOUND', 'message': 'none', 'requestId': 'r'},
        });
        return;
      }
      _writeJson(request, 200, {
        'bundle': bundle,
        'updatedAt': '2026-11-01T10:00:00Z',
        'updatedByDeviceId': 'device',
      });
    } else if (path == '/api/v1/users/me/recovery' && method == 'PUT') {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final encoded = base64Decode(body['bundle'] as String);
      final publicKey = base64Decode(
        body['accountIdentityPublicKey'] as String,
      );
      final valid = await Ed25519().verify(
        await recoveryBundleStatement(accountId: userId, bundle: encoded),
        signature: Signature(
          base64Decode(body['signature'] as String),
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
      if (!valid) {
        _writeJson(request, 400, {
          'error': {
            'code': 'VALIDATION_ERROR',
            'message': 'recovery bundle signature is invalid',
            'requestId': 'r',
          },
        });
        return;
      }
      bundle = body['bundle'] as String;
      accountIdentityPublicKey = publicKey;
      uploads++;
      request.response.statusCode = 204;
      await request.response.close();
    } else {
      request.response.statusCode = 404;
      await request.response.close();
    }
  }

  void _writeJson(HttpRequest request, int status, Object body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    request.response.close();
  }
}

Future<ServerConnectionController> _signedInDevice(HttpServer server) async {
  final controller = ServerConnectionController(
    deviceIdentityStore: DeviceIdentityStore(MemoryDevicePrivateKeyStorage()),
    serverStore: PinnedServerStore(MemoryPinnedServerStorage()),
    sessionStore: SessionStore(MemorySessionStorage()),
  );
  await controller.discover('127.0.0.1:${server.port}');
  await controller.confirmTrust();
  await controller.login('admin', 'correct horse battery staple');
  if (controller.status != ServerConnectionStatus.authenticated) {
    throw StateError('sign-in failed: ${controller.errorMessage}');
  }
  return controller;
}

Future<List<int>> _bytesOf(SecretKey key) => key.extractBytes();

void main() {
  test('the vault creator uploads its recovery bundle and a clean device restores from the Recovery Secret alone', () async {
    final fakeServer = _FakeRecoveryServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));

    final creatorConnection = await _signedInDevice(httpServer);
    addTearDown(creatorConnection.dispose);
    final creatorStore = VaultKeyStore(MemoryVaultKeyStorage());
    final secret = await creatorStore.createVault(
      userId: _FakeRecoveryServer.userId,
    );
    final exportedSecret = await secret.export();
    secret.destroy();
    final creator = RecoveryController(
      vaultKeyStore: creatorStore,
      serverConnection: creatorConnection,
    );
    addTearDown(creator.dispose);

    await creator.refresh();
    expect(
      creator.status,
      RecoveryBackupStatus.protected,
      reason: creator.errorMessage,
    );
    expect(fakeServer.uploads, 1);
    final creatorIdentity = await AccountIdentity.derive(
      vaultKey: (await creatorStore.loadVaultKey())!,
      accountId: _FakeRecoveryServer.userId,
    );
    expect(
      fakeServer.accountIdentityPublicKey,
      creatorIdentity.publicKey.bytes,
    );
    creatorIdentity.destroy();

    // A second check finds the server copy and does not upload again.
    await creator.refresh();
    expect(fakeServer.uploads, 1);

    final cleanConnection = await _signedInDevice(httpServer);
    addTearDown(cleanConnection.dispose);
    final cleanStore = VaultKeyStore(MemoryVaultKeyStorage());
    final clean = RecoveryController(
      vaultKeyStore: cleanStore,
      serverConnection: cleanConnection,
    );
    addTearDown(clean.dispose);

    expect(await clean.restoreVault('not a secret'), isFalse);
    expect(clean.errorMessage, contains('HBXR1-'));
    expect(
      await clean.restoreVault(
        'HBXR1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ),
      isFalse,
    );
    expect(clean.errorMessage, contains('does not belong'));
    expect(await cleanStore.exists(), isFalse);

    expect(
      await clean.restoreVault('  $exportedSecret\n'),
      isTrue,
      reason: clean.errorMessage,
    );
    expect(
      await _bytesOf((await cleanStore.loadVaultKey())!),
      await _bytesOf((await creatorStore.loadVaultKey())!),
    );
    expect(clean.status, RecoveryBackupStatus.protected);
  });

  test('a provisioned device without recovery material can issue a new Recovery Secret', () async {
    final fakeServer = _FakeRecoveryServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final connection = await _signedInDevice(httpServer);
    addTearDown(connection.dispose);
    final store = VaultKeyStore(MemoryVaultKeyStorage());
    final vaultKey = SecretKeyData(List<int>.generate(32, (index) => index));
    await store.saveProvisionedVaultKey(vaultKey);
    final controller = RecoveryController(
      vaultKeyStore: store,
      serverConnection: connection,
    );
    addTearDown(controller.dispose);

    await controller.refresh();
    expect(controller.status, RecoveryBackupStatus.unprotected);
    expect(fakeServer.uploads, 0);

    final newSecret = await controller.createNewRecoverySecret();
    expect(newSecret, startsWith('HBXR1-'), reason: controller.errorMessage);
    expect(controller.status, RecoveryBackupStatus.protected);
    expect(fakeServer.uploads, 1);
    expect(await store.loadRecoveryPackage(), isNotNull);

    final cleanConnection = await _signedInDevice(httpServer);
    addTearDown(cleanConnection.dispose);
    final cleanStore = VaultKeyStore(MemoryVaultKeyStorage());
    final clean = RecoveryController(
      vaultKeyStore: cleanStore,
      serverConnection: cleanConnection,
    );
    addTearDown(clean.dispose);
    expect(
      await clean.restoreVault(newSecret!),
      isTrue,
      reason: clean.errorMessage,
    );
    expect(
      await _bytesOf((await cleanStore.loadVaultKey())!),
      await _bytesOf(vaultKey),
    );
    vaultKey.destroy();
  });

  test('restore explains when the server holds no recovery data', () async {
    final fakeServer = _FakeRecoveryServer();
    final httpServer = await fakeServer.start();
    addTearDown(() => httpServer.close(force: true));
    final connection = await _signedInDevice(httpServer);
    addTearDown(connection.dispose);
    final store = VaultKeyStore(MemoryVaultKeyStorage());
    final controller = RecoveryController(
      vaultKeyStore: store,
      serverConnection: connection,
    );
    addTearDown(controller.dispose);

    final secret = await VaultKeyStore(MemoryVaultKeyStorage())
        .createVault(userId: _FakeRecoveryServer.userId);
    final exported = await secret.export();
    secret.destroy();
    expect(await controller.restoreVault(exported), isFalse);
    expect(controller.errorMessage, contains('no recovery data'));
    expect(await store.exists(), isFalse);
  });
}
