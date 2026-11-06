// Constructor parameters are named for readable call sites, as elsewhere.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../core/e2ee/account_identity.dart';
import '../../core/e2ee/device_identity.dart';
import '../../core/e2ee/family_share_key.dart';
import '../../core/e2ee/key_ring.dart';
import '../../core/e2ee/opaque_id.dart';
import '../../core/e2ee/scoped_metadata.dart';
import '../../core/e2ee/vault_key_store.dart';
import '../../core/storage/node_cache.dart';
import '../../core/transport/homebox_api_client.dart' as transport;
import '../../core/util/user_facing_error.dart';
import '../server/server_connection_controller.dart';
import '../sync/sync_engine.dart';
import 'key_scopes.dart';
import 'shared_folder_browser.dart';
import 'shared_scope_reconciler.dart';

/// How far an incoming share is from being usable on this device.
enum IncomingShareState {
  /// Verified and this device holds the folder key.
  ready,

  /// The owner's account fingerprint has not been compared on this device.
  unverified,

  /// The envelopes are signed by a different identity than the one pinned
  /// for this owner: possibly a server attack. Never opened.
  identityChanged,

  /// The owner has not delivered the folder key to this device yet.
  waitingForKey,

  /// An envelope failed signature or decryption checks.
  invalid,
}

/// A family member's account looked up for sharing, with only the devices
/// whose keys that account's identity certified.
final class RecipientCandidate {
  const RecipientCandidate({
    required this.accountId,
    required this.identityPublicKey,
    required this.fingerprint,
    required this.devices,
    required this.alreadyTrusted,
  });

  final String accountId;
  final Uint8List identityPublicKey;
  final String fingerprint;
  final List<transport.ShareableDevice> devices;

  /// True when this device pinned exactly this identity before, so the
  /// fingerprint comparison can be skipped.
  final bool alreadyTrusted;
}

final class OutgoingShareView {
  const OutgoingShareView({
    required this.share,
    required this.folderName,
    required this.recipientTrusted,
  });

  final transport.FamilyShare share;
  final String folderName;

  /// Whether this device can deliver keys to the member's devices without
  /// another fingerprint comparison.
  final bool recipientTrusted;
}

final class IncomingShareView {
  const IncomingShareView({
    required this.share,
    required this.state,
    this.folderName,
    this.ownerIdentityPublicKey,
    this.ownerFingerprint,
  });

  final transport.FamilyShare share;
  final IncomingShareState state;
  final String? folderName;
  final Uint8List? ownerIdentityPublicKey;
  final String? ownerFingerprint;
}

/// Family Vault (spec §28, ADR-023) for this account: folders it shares
/// with family members, folders shared with it, and the key management
/// behind both. Every key is generated, wrapped, signed, and opened here on
/// the client; the server only stores and relays ciphertext.
final class FamilyVaultController extends ChangeNotifier {
  FamilyVaultController({
    required ServerConnectionController serverConnection,
    required VaultKeyStore vaultKeyStore,
    required DeviceIdentityStore deviceIdentityStore,
    required SyncEngine syncEngine,
  }) : _serverConnection = serverConnection,
       _vaultKeyStore = vaultKeyStore,
       _deviceIdentityStore = deviceIdentityStore,
       _syncEngine = syncEngine,
       _reconciler = SharedScopeReconciler(syncEngine: syncEngine) {
    _syncEngine.addListener(_onSyncEngineChanged);
  }

  final ServerConnectionController _serverConnection;
  final VaultKeyStore _vaultKeyStore;
  final DeviceIdentityStore _deviceIdentityStore;
  final SyncEngine _syncEngine;
  final SharedScopeReconciler _reconciler;
  final FamilyShareKeyCipher _shareCipher = FamilyShareKeyCipher();

  List<OutgoingShareView> _outgoing = const [];
  List<IncomingShareView> _incoming = const [];
  String? _accountFingerprint;
  bool _loading = false;
  bool _busy = false;
  String? _busyMessage;
  String? _errorMessage;
  String? _noticeMessage;
  bool _disposed = false;
  bool _reconciling = false;
  bool _reconcileAgain = false;
  bool _loadedOnce = false;
  DateTime? _lastReconcile;

  List<OutgoingShareView> get outgoing => _outgoing;
  List<IncomingShareView> get incoming => _incoming;
  bool get loading => _loading;
  bool get busy => _busy;

  /// What a long-running operation is doing, for its progress indicator.
  String? get busyMessage => _busyMessage;
  String? get errorMessage => _errorMessage;

  /// A non-error outcome the user should know about, such as members that
  /// still need a fingerprint check after a key rotation.
  String? get noticeMessage => _noticeMessage;
  String? get accountId => _serverConnection.session?.user.id;

  /// SHA-256 of this account's identity key, which family members compare
  /// out of band before sharing with it or trusting what it shares.
  String? get accountFingerprint => _accountFingerprint;

  /// Outgoing shares of [folderId].
  List<OutgoingShareView> sharesOf(String folderId) => [
    for (final view in _outgoing)
      if (view.share.nodeId == folderId) view,
  ];

  /// Whether [folderId] currently has at least one member.
  bool isShared(String folderId) =>
      _outgoing.any((view) => view.share.nodeId == folderId);

  /// Whether [folder] can be shared: it is a folder of this account that
  /// neither sits inside nor contains another shared folder.
  bool canShare(LocalNode folder) {
    if (!folder.isDirectory || folder.isDeleted) return false;
    final userId = accountId;
    if (userId == null) return false;
    final keyed = _syncEngine.folderKeys.isKeyedFolder;
    if (keyed(folder.id)) return true;
    final scopes = KeyScopeResolver(
      nodeCache: _syncEngine.nodeCache,
      isKeyedFolder: keyed,
      userId: userId,
    );
    return scopes.nearestKeyedFolder(folder.parentId) == null &&
        !scopes.subtreeHasKeyedFolder(folder.id, includeSelf: false);
  }

  void clearMessages() {
    _errorMessage = null;
    _noticeMessage = null;
    _notify();
  }

  /// Reloads both share lists and this account's fingerprint. Keys newly
  /// approved devices of verified members need are delivered on the way.
  /// [quiet] keeps a missing session or vault from being reported, for
  /// background loads the user did not ask for.
  Future<void> refresh({bool quiet = false}) async {
    final ctx = await _context(quiet: quiet);
    if (ctx == null) return;
    _loadedOnce = true;
    _loading = true;
    _notify();
    try {
      _accountFingerprint ??= await _ownFingerprint(ctx);
      final outgoing = await ctx.api.listOutgoingShares(ctx.accessToken);
      await _deliverMissingKeysSilently(ctx, outgoing);
      _outgoing = await _describeOutgoing(
        ctx,
        await ctx.api.listOutgoingShares(ctx.accessToken),
      );
      _incoming = await _describeIncoming(
        ctx,
        await ctx.api.listIncomingShares(ctx.accessToken),
      );
      _errorMessage = null;
    } catch (e) {
      _errorMessage = describeError(e);
    } finally {
      _loading = false;
      ctx.keys.dispose();
      _notify();
    }
  }

  /// Looks up the family member with [accountId] and checks every device
  /// certificate against that account's identity. The caller must show
  /// [RecipientCandidate.fingerprint] for comparison unless it is
  /// [RecipientCandidate.alreadyTrusted].
  Future<RecipientCandidate?> lookupRecipient(String accountId) async {
    final trimmed = accountId.trim().toLowerCase();
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(trimmed)) {
      _fail('Enter the account ID the family member copied from HomeBox.');
      return null;
    }
    final ctx = await _context();
    if (ctx == null) return null;
    try {
      if (trimmed == ctx.userId) {
        _fail('A folder cannot be shared with your own account.');
        return null;
      }
      final devices = await ctx.api.listShareableDevices(
        ctx.accessToken,
        trimmed,
      );
      final identity = _commonIdentity(devices);
      if (identity == null) {
        _fail(
          'This account has no approved device with a verifiable key yet. '
          'Ask the family member to open HomeBox and finish setting up '
          'their vault first.',
        );
        return null;
      }
      final pinned = _syncEngine.trustedAccounts.identityOf(trimmed);
      if (pinned != null && !_sameBytes(pinned, identity)) {
        _fail(
          'The identity of this account changed since you verified it. '
          'Do not share until you have compared the fingerprint again.',
        );
        return null;
      }
      final verified = await _certifiedDevices(trimmed, identity, devices);
      if (verified.isEmpty) {
        _fail('None of this account\'s devices has a valid certificate.');
        return null;
      }
      return RecipientCandidate(
        accountId: trimmed,
        identityPublicKey: identity,
        fingerprint: await devicePublicKeyFingerprint(identity),
        devices: verified,
        alreadyTrusted: pinned != null,
      );
    } catch (e) {
      _fail(describeError(e));
      return null;
    } finally {
      ctx.keys.dispose();
    }
  }

  /// Shares [folderId] with [candidate] after the user compared its
  /// fingerprint. Turns the folder into its own key scope if needed,
  /// re-encrypts everything below it with the folder key, then delivers
  /// signed envelopes of every key version to each certified device.
  Future<bool> shareFolder({
    required String folderId,
    required RecipientCandidate candidate,
    required String permission,
  }) async {
    final ctx = await _context();
    if (ctx == null) return false;
    _setBusy('Preparing the folder for sharing…');
    try {
      _syncEngine.trustedAccounts.pin(
        candidate.accountId,
        candidate.identityPublicKey,
      );
      // Another owner device may already have created or rotated this
      // folder's key; never create a version from a stale local copy.
      await _refreshFolderKeys(ctx);
      await _ensureFolderKey(ctx, folderId);
      // Bring the local tree up to date first so nothing recently added
      // elsewhere stays encrypted with the personal Vault Key.
      await _syncEngine.runOnce();
      _setBusy('Encrypting the folder with its own key…');
      final prepared = await _reconciler.reconcile(
        api: ctx.api,
        accessToken: ctx.accessToken,
        keys: ctx.keys,
        folderIds: [folderId],
      );
      _noticeMessage = prepared.skipped == 0
          ? null
          : '${prepared.skipped} item(s) in this folder could not be '
                'prepared for sharing yet. HomeBox retries after the next '
                'sync; until then only you can open them.';
      _setBusy('Sending the folder key to the family member…');
      final envelopes = await _envelopesFor(
        ctx,
        folderId: folderId,
        recipientAccountId: candidate.accountId,
        devices: candidate.devices,
        versions: _versionsOf(ctx.keys, folderId),
      );
      final first = envelopes.take(32).toList(growable: false);
      final share = await ctx.api.createShare(
        ctx.accessToken,
        operationId: generateUuidV4(),
        nodeId: folderId,
        targetUserId: candidate.accountId,
        permission: permission,
        envelopes: first,
      );
      await _sendInChunks(ctx, share.id, envelopes.skip(32).toList());
      await _reloadOutgoing(ctx);
      _errorMessage = null;
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      return false;
    } finally {
      ctx.keys.dispose();
      _clearBusy();
    }
  }

  /// Removes a member and rotates the folder key (spec §28.3): everything
  /// added from now on uses a new key version the member never receives,
  /// and the server stops serving the folder to them. Content they could
  /// already read stays readable to them; that cannot be revoked.
  ///
  /// The key is rotated and delivered to the remaining members first, and
  /// access is removed last. If anything fails, the share is still listed,
  /// so the user can simply try again; a retry may add one more key
  /// version, which is harmless.
  Future<bool> revoke(OutgoingShareView view) async {
    final ctx = await _context();
    if (ctx == null) return false;
    _setBusy('Rotating the folder key…');
    try {
      final folderId = view.share.nodeId;
      await _refreshFolderKeys(ctx);
      await _rotateFolderKey(ctx, folderId);
      final remaining = (await ctx.api.listOutgoingShares(ctx.accessToken))
          .where(
            (share) => share.nodeId == folderId && share.id != view.share.id,
          )
          .toList();
      final unverified = <String>[];
      for (final share in remaining) {
        if (!await _deliverMissingKeys(ctx, share)) {
          unverified.add(share.targetUsername);
        }
      }
      _setBusy('Removing access…');
      await ctx.api.revokeShare(ctx.accessToken, view.share.id);
      await _reloadOutgoing(ctx);
      _noticeMessage = unverified.isEmpty
          ? null
          : 'Verify ${unverified.join(', ')} on this device to give them the '
                'new folder key; until then they cannot add or read new content.';
      _errorMessage = null;
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      return false;
    } finally {
      ctx.keys.dispose();
      _clearBusy();
    }
  }

  /// Delivers every key version of [view]'s folder to the member's
  /// certified devices that lack one, after pinning [candidate] if this
  /// device had not verified that member yet.
  Future<bool> deliverKeys(
    OutgoingShareView view, {
    RecipientCandidate? candidate,
  }) async {
    final ctx = await _context();
    if (ctx == null) return false;
    _setBusy('Sending the folder key to new devices…');
    try {
      if (candidate != null) {
        _syncEngine.trustedAccounts.pin(
          candidate.accountId,
          candidate.identityPublicKey,
        );
      }
      if (!await _deliverMissingKeys(ctx, view.share)) {
        _fail('Verify this family member first.');
        return false;
      }
      await _reloadOutgoing(ctx);
      _noticeMessage = null;
      return true;
    } catch (e) {
      _errorMessage = describeError(e);
      return false;
    } finally {
      ctx.keys.dispose();
      _clearBusy();
    }
  }

  /// Pins the owner identity of [view] after the user compared its
  /// fingerprint, so its envelopes are trusted on this device.
  Future<void> trustOwner(IncomingShareView view) async {
    final identity = view.ownerIdentityPublicKey;
    if (identity == null) return;
    _syncEngine.trustedAccounts.pin(view.share.ownerUserId, identity);
    await refresh();
  }

  /// Opens the keys of a ready incoming share for browsing. The caller owns
  /// the returned browser and must dispose it.
  Future<SharedFolderBrowser?> open(IncomingShareView view) async {
    if (view.state != IncomingShareState.ready) return null;
    final ctx = await _context();
    if (ctx == null) return null;
    ctx.keys.dispose();
    try {
      final keys = await _openIncomingKeys(ctx.userId, ctx.deviceId, view);
      if (keys == null) {
        _fail('This shared folder cannot be opened on this device.');
        return null;
      }
      return SharedFolderBrowser(
        serverConnection: _serverConnection,
        share: view.share,
        rootName: view.folderName ?? 'Shared folder',
        keys: keys,
      );
    } catch (e) {
      _fail(describeError(e));
      return null;
    }
  }

  // --- owner side ---

  Future<void> _ensureFolderKey(_Context ctx, String folderId) async {
    if (ctx.keys.latestVersion(folderId) > 0) return;
    await _createFolderKeyVersion(ctx, folderId, homeBoxFirstFolderKeyVersion);
  }

  Future<void> _rotateFolderKey(_Context ctx, String folderId) =>
      _createFolderKeyVersion(
        ctx,
        folderId,
        ctx.keys.latestVersion(folderId) + 1,
      );

  Future<void> _createFolderKeyVersion(
    _Context ctx,
    String folderId,
    int version,
  ) async {
    final folderKey = newFolderKey();
    try {
      final envelope = await wrapFolderKeyForOwner(
        vaultKey: ctx.keys.vaultKey.key,
        folderKey: folderKey,
        folderId: folderId,
        ownerUserId: ctx.userId,
        version: version,
      );
      try {
        await ctx.api.createFolderKey(
          ctx.accessToken,
          folderId,
          keyVersion: version,
          ownerEnvelope: envelope,
        );
      } on transport.HomeBoxApiException catch (e) {
        // Another owner device created this version first. Its key is just
        // as new, so adopt it instead of failing.
        if (e.code != 'REVISION_CONFLICT') rethrow;
        await _refreshFolderKeys(ctx);
        if (ctx.keys.latestVersion(folderId) < version) rethrow;
        return;
      }
      _syncEngine.folderKeys.add(folderId, version, envelope);
      ctx.keys.addWrapped(folderId, version, envelope);
    } finally {
      folderKey.destroy();
    }
  }

  /// Merges the server's folder keys into the local cache and [ctx]'s ring.
  Future<void> _refreshFolderKeys(_Context ctx) async {
    final records = await ctx.api.listFolderKeys(ctx.accessToken);
    _syncEngine.folderKeys.mergeAll(records);
    for (final record in records) {
      ctx.keys.addWrapped(
        record.folderId,
        record.keyVersion,
        record.ownerEnvelope,
      );
    }
  }

  List<int> _versionsOf(OwnerKeyRing keys, String folderId) => [
    for (var v = 1; v <= keys.latestVersion(folderId); v++) v,
  ];

  /// Delivers missing envelopes for [share]. Returns false when this device
  /// has not verified the member, so it cannot trust their devices.
  Future<bool> _deliverMissingKeys(
    _Context ctx,
    transport.FamilyShare share,
  ) async {
    final pinned = _syncEngine.trustedAccounts.identityOf(share.targetUserId);
    if (pinned == null) return false;
    final List<transport.ShareableDevice> devices;
    try {
      devices = await ctx.api.listShareableDevices(
        ctx.accessToken,
        share.targetUserId,
      );
    } on transport.HomeBoxApiException catch (e) {
      if (e.code == 'NOT_FOUND') return true; // no active device right now.
      rethrow;
    }
    final certified = await _certifiedDevices(
      share.targetUserId,
      pinned,
      devices,
    );
    final have = {
      for (final envelope in share.envelopes)
        '${envelope.targetDeviceId}/${envelope.keyVersion}',
    };
    final versions = _versionsOf(ctx.keys, share.nodeId);
    final missing = <transport.FamilyShareEnvelope>[];
    for (final device in certified) {
      final needed = [
        for (final v in versions)
          if (!have.contains('${device.id}/$v')) v,
      ];
      if (needed.isEmpty) continue;
      missing.addAll(
        await _envelopesFor(
          ctx,
          folderId: share.nodeId,
          recipientAccountId: share.targetUserId,
          devices: [device],
          versions: needed,
        ),
      );
    }
    await _sendInChunks(ctx, share.id, missing);
    return true;
  }

  Future<void> _deliverMissingKeysSilently(
    _Context ctx,
    List<transport.FamilyShare> shares,
  ) async {
    for (final share in shares) {
      try {
        await _deliverMissingKeys(ctx, share);
      } catch (_) {
        // Best effort on refresh; the explicit action reports errors.
      }
    }
  }

  Future<void> _sendInChunks(
    _Context ctx,
    String shareId,
    List<transport.FamilyShareEnvelope> envelopes,
  ) async {
    for (var start = 0; start < envelopes.length; start += 32) {
      await ctx.api.addShareEnvelopes(
        ctx.accessToken,
        shareId,
        envelopes: envelopes.sublist(
          start,
          (start + 32).clamp(0, envelopes.length),
        ),
      );
    }
  }

  /// Encrypts each requested key version of [folderId] for each device and
  /// signs every envelope with this account's identity.
  Future<List<transport.FamilyShareEnvelope>> _envelopesFor(
    _Context ctx, {
    required String folderId,
    required String recipientAccountId,
    required List<transport.ShareableDevice> devices,
    required List<int> versions,
  }) async {
    final identity = await AccountIdentity.derive(
      vaultKey: ctx.keys.vaultKey.key,
      accountId: ctx.userId,
    );
    try {
      final result = <transport.FamilyShareEnvelope>[];
      for (final version in versions) {
        final folderKey = await ctx.keys.key(folderId, version);
        for (final device in devices) {
          final envelope = await _shareCipher.create(
            folderKey: folderKey.key,
            keyVersion: version,
            folderId: uuidStringToBytes(folderId),
            ownerUserId: uuidStringToBytes(ctx.userId),
            recipientUserId: uuidStringToBytes(recipientAccountId),
            recipientDeviceId: uuidStringToBytes(device.id),
            recipientPublicKey: SimplePublicKey(
              device.publicKey,
              type: KeyPairType.x25519,
            ),
          );
          final encoded = envelope.encode();
          result.add(
            transport.FamilyShareEnvelope(
              targetDeviceId: device.id,
              keyVersion: version,
              ciphertext: encoded,
              ownerIdentityPublicKey: Uint8List.fromList(
                identity.publicKey.bytes,
              ),
              ownerSignature: await identity.signFamilyShareEnvelope(
                folderId: folderId,
                ownerAccountId: ctx.userId,
                recipientAccountId: recipientAccountId,
                recipientDeviceId: device.id,
                keyVersion: version,
                envelope: encoded,
              ),
            ),
          );
        }
      }
      return result;
    } finally {
      identity.destroy();
    }
  }

  Future<void> _reloadOutgoing(_Context ctx) async {
    _outgoing = await _describeOutgoing(
      ctx,
      await ctx.api.listOutgoingShares(ctx.accessToken),
    );
  }

  Future<List<OutgoingShareView>> _describeOutgoing(
    _Context ctx,
    List<transport.FamilyShare> shares,
  ) async {
    final result = <OutgoingShareView>[];
    for (final share in shares) {
      result.add(
        OutgoingShareView(
          share: share,
          folderName: await _ownFolderName(ctx, share.nodeId),
          recipientTrusted:
              _syncEngine.trustedAccounts.identityOf(share.targetUserId) !=
              null,
        ),
      );
    }
    return result;
  }

  Future<String> _ownFolderName(_Context ctx, String folderId) async {
    final node = _syncEngine.nodeCache.getById(folderId);
    if (node == null) return 'Shared folder';
    try {
      return (await decryptNodeMetadata(
        keys: ctx.keys,
        ciphertext: node.metadataCiphertext,
        scopeId: node.scopeOrOwner(ctx.userId),
        isDirectory: true,
        nodeId: node.id,
      )).fileName;
    } catch (_) {
      return 'Shared folder';
    }
  }

  Future<String?> _ownFingerprint(_Context ctx) async {
    final identity = await AccountIdentity.derive(
      vaultKey: ctx.keys.vaultKey.key,
      accountId: ctx.userId,
    );
    try {
      return await devicePublicKeyFingerprint(identity.publicKey.bytes);
    } finally {
      identity.destroy();
    }
  }

  /// The single identity key all certified devices of an account share, or
  /// null when there is none or they disagree.
  Uint8List? _commonIdentity(List<transport.ShareableDevice> devices) {
    Uint8List? identity;
    for (final device in devices) {
      final key = device.authentication?.accountIdentityPublicKey;
      if (key == null) continue;
      if (identity == null) {
        identity = key;
      } else if (!_sameBytes(identity, key)) {
        return null;
      }
    }
    return identity;
  }

  Future<List<transport.ShareableDevice>> _certifiedDevices(
    String accountId,
    List<int> identity,
    List<transport.ShareableDevice> devices,
  ) async {
    final result = <transport.ShareableDevice>[];
    for (final device in devices) {
      final auth = device.authentication;
      if (auth == null) continue;
      final valid = await verifyDeviceCertificate(
        identityPublicKey: identity,
        certificate: DeviceKeyCertificate(
          signatureVersion: auth.signatureVersion,
          deviceKeyVersion: auth.deviceKeyVersion,
          accountIdentityPublicKey: auth.accountIdentityPublicKey,
          signature: auth.publicKeySignature,
        ),
        accountId: accountId,
        deviceId: device.id,
        devicePublicKey: device.publicKey,
      );
      if (valid) result.add(device);
    }
    return result;
  }

  // --- recipient side ---

  Future<List<IncomingShareView>> _describeIncoming(
    _Context ctx,
    List<transport.FamilyShare> shares,
  ) async {
    final result = <IncomingShareView>[];
    for (final share in shares) {
      result.add(await _describeIncomingShare(ctx, share));
    }
    return result;
  }

  Future<IncomingShareView> _describeIncomingShare(
    _Context ctx,
    transport.FamilyShare share,
  ) async {
    if (share.envelopes.isEmpty) {
      return IncomingShareView(
        share: share,
        state: IncomingShareState.waitingForKey,
      );
    }
    final identity = share.envelopes.first.ownerIdentityPublicKey;
    if (identity == null ||
        share.envelopes.any(
          (e) =>
              e.ownerIdentityPublicKey == null ||
              !_sameBytes(e.ownerIdentityPublicKey!, identity),
        )) {
      return IncomingShareView(share: share, state: IncomingShareState.invalid);
    }
    final fingerprint = await devicePublicKeyFingerprint(identity);
    final pinned = _syncEngine.trustedAccounts.identityOf(share.ownerUserId);
    if (pinned == null) {
      return IncomingShareView(
        share: share,
        state: IncomingShareState.unverified,
        ownerIdentityPublicKey: identity,
        ownerFingerprint: fingerprint,
      );
    }
    if (!_sameBytes(pinned, identity)) {
      return IncomingShareView(
        share: share,
        state: IncomingShareState.identityChanged,
        ownerIdentityPublicKey: identity,
        ownerFingerprint: fingerprint,
      );
    }
    final view = IncomingShareView(
      share: share,
      state: IncomingShareState.ready,
      ownerIdentityPublicKey: identity,
      ownerFingerprint: fingerprint,
    );
    SharedKeyRing? keys;
    try {
      keys = await _openIncomingKeys(ctx.userId, ctx.deviceId, view);
      if (keys == null) {
        return IncomingShareView(
          share: share,
          state: IncomingShareState.invalid,
          ownerFingerprint: fingerprint,
        );
      }
      final root = await ctx.api.getNode(ctx.accessToken, share.nodeId);
      final metadata = await decryptNodeMetadata(
        keys: keys,
        ciphertext: root.metadataCiphertext,
        scopeId: share.nodeId,
        isDirectory: true,
        nodeId: share.nodeId,
      );
      return IncomingShareView(
        share: share,
        state: IncomingShareState.ready,
        folderName: metadata.fileName,
        ownerIdentityPublicKey: identity,
        ownerFingerprint: fingerprint,
      );
    } catch (_) {
      // The root may still be encrypted with the owner's old key while the
      // owner's device finishes preparing it; the share is still usable.
      return view;
    } finally {
      keys?.dispose();
    }
  }

  /// Verifies and opens every envelope of a trusted incoming share.
  Future<SharedKeyRing?> _openIncomingKeys(
    String userId,
    String deviceId,
    IncomingShareView view,
  ) async {
    final pinned = _syncEngine.trustedAccounts.identityOf(
      view.share.ownerUserId,
    );
    if (pinned == null) return null;
    final device = await _deviceIdentityStore.load();
    if (device == null) return null;
    final keys = <int, SecretKey>{};
    try {
      for (final envelope in view.share.envelopes) {
        if (envelope.targetDeviceId != deviceId) continue;
        final signature = envelope.ownerSignature;
        final identity = envelope.ownerIdentityPublicKey;
        if (signature == null ||
            identity == null ||
            !_sameBytes(identity, pinned) ||
            !await AccountIdentity.verifyFamilyShareEnvelope(
              ownerIdentityPublicKey: pinned,
              signature: signature,
              folderId: view.share.nodeId,
              ownerAccountId: view.share.ownerUserId,
              recipientAccountId: userId,
              recipientDeviceId: deviceId,
              keyVersion: envelope.keyVersion,
              envelope: envelope.ciphertext,
            )) {
          throw const FormatException('A share envelope is not authentic.');
        }
        final decoded = FamilyShareKeyEnvelope.decode(envelope.ciphertext);
        if (decoded.keyVersion != envelope.keyVersion) {
          throw const FormatException(
            'A share envelope has the wrong version.',
          );
        }
        keys[envelope.keyVersion] = await _shareCipher.open(
          envelope: decoded,
          recipientKeyPair: device.keyPair,
          folderId: uuidStringToBytes(view.share.nodeId),
          ownerUserId: uuidStringToBytes(view.share.ownerUserId),
          recipientUserId: uuidStringToBytes(userId),
          recipientDeviceId: uuidStringToBytes(deviceId),
        );
      }
    } catch (_) {
      for (final key in keys.values) {
        key.destroy();
      }
      return null;
    } finally {
      device.destroy();
    }
    if (keys.isEmpty) return null;
    return SharedKeyRing({view.share.nodeId: keys});
  }

  // --- background reconciliation ---

  /// The shortest time between two background sweeps of shared folders.
  static const Duration reconcileInterval = Duration(minutes: 2);

  void _onSyncEngineChanged() {
    if (_syncEngine.status != SyncStatus.idle) return;
    // Load the share lists once in the background, so Files can mark
    // shared folders before the Family page was ever opened.
    if (!_loadedOnce && !_loading) unawaited(refresh(quiet: true));
    final last = _lastReconcile;
    if (last != null && DateTime.now().difference(last) < reconcileInterval) {
      return;
    }
    unawaited(_reconcileInBackground());
  }

  Future<void> _reconcileInBackground() async {
    if (_reconciling || _busy) {
      _reconcileAgain = true;
      return;
    }
    _reconciling = true;
    try {
      do {
        _reconcileAgain = false;
        _lastReconcile = DateTime.now();
        final userId = accountId;
        final folders = _syncEngine.folderKeys.keyedFolderIds();
        // A walk of the local cache needs no key; only read the Vault Key
        // from secure storage when something actually has to move.
        if (userId == null ||
            folders.isEmpty ||
            _reconciler
                .staleNodes(userId: userId, folderIds: folders)
                .isEmpty) {
          continue;
        }
        final ctx = await _context(quiet: true);
        if (ctx == null) return;
        try {
          await _reconciler.reconcile(
            api: ctx.api,
            accessToken: ctx.accessToken,
            keys: ctx.keys,
            folderIds: folders,
          );
        } catch (_) {
          // Only a network failure ends a pass early; the next sync retries.
        } finally {
          ctx.keys.dispose();
        }
      } while (_reconcileAgain && !_disposed);
    } finally {
      _reconciling = false;
    }
  }

  // --- helpers ---

  Future<_Context?> _context({bool quiet = false}) async {
    final api = _serverConnection.api;
    final session = await _serverConnection.ensureFreshSession();
    final keys = session == null
        ? null
        : await openOwnerKeyRing(
            vaultKeyStore: _vaultKeyStore,
            userId: session.user.id,
            wrappedFolderKeys: _syncEngine.folderKeys.all(),
          );
    if (api == null || session == null || keys == null) {
      keys?.dispose();
      if (!quiet) {
        _fail('Connect to a server, sign in, and set up the vault first.');
      }
      return null;
    }
    return _Context(
      api: api,
      accessToken: session.accessToken,
      userId: session.user.id,
      deviceId: session.device.id,
      keys: keys,
    );
  }

  void _setBusy(String message) {
    _busy = true;
    _busyMessage = message;
    _notify();
  }

  void _clearBusy() {
    _busy = false;
    _busyMessage = null;
    _notify();
    if (_reconcileAgain) unawaited(_reconcileInBackground());
  }

  void _fail(String message) {
    _errorMessage = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncEngine.removeListener(_onSyncEngineChanged);
    super.dispose();
  }
}

final class _Context {
  const _Context({
    required this.api,
    required this.accessToken,
    required this.userId,
    required this.deviceId,
    required this.keys,
  });

  final transport.HomeBoxApiClient api;
  final String accessToken;
  final String userId;
  final String deviceId;
  final OwnerKeyRing keys;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
