import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/e2ee/account_identity.dart';
import 'core/e2ee/device_identity.dart';
import 'core/e2ee/vault_key_store.dart';
import 'core/localization/app_locale_controller.dart';
import 'core/platform/android_file_saver.dart';
import 'core/platform/android_file_sharer.dart';
import 'core/platform/android_sync_folder.dart';
import 'core/platform/biometric_authenticator.dart';
import 'core/platform/camera_photo_picker.dart';
import 'core/platform/windows_autostart.dart';
import 'core/platform/windows_file_drop.dart';
import 'core/platform/windows_sync_folder.dart';
import 'core/storage/local_database.dart';
import 'core/util/local_path.dart';
import 'features/device/device_setup_controller.dart';
import 'features/device/device_provisioning_controller.dart';
import 'features/files/download_notification_controller.dart';
import 'features/files/files_controller.dart';
import 'features/server/server_connection_controller.dart';
import 'features/sync/sync_engine.dart';
import 'features/syncfolder/local_folder_uploader.dart';
import 'features/syncfolder/sync_folder_materializer.dart';
import 'features/syncfolder/sync_folder_store.dart';
import 'features/syncfolder/sync_folder_watcher.dart';
import 'features/vault/vault_setup_controller.dart';
import 'core/transport/homebox_api_client.dart' as transport;

void main() => runApp(const HomeBoxApp());

class HomeBoxApp extends StatefulWidget {
  const HomeBoxApp({
    super.key,
    this.deviceIdentityStore,
    this.serverConnectionController,
    this.vaultKeyStore,
    this.syncFolderStore,
    this.cameraPhotoPicker,
    this.biometricAuthenticator,
    this.androidFileSaver,
    this.androidFileSharer,
    this.androidSyncFolder,
    this.localeController,
  });

  final DeviceIdentityStore? deviceIdentityStore;
  final ServerConnectionController? serverConnectionController;
  final VaultKeyStore? vaultKeyStore;
  final SyncFolderStore? syncFolderStore;
  final CameraPhotoPicker? cameraPhotoPicker;
  final BiometricAuthenticator? biometricAuthenticator;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;
  final AndroidSyncFolder? androidSyncFolder;
  final AppLocaleController? localeController;

  @override
  State<HomeBoxApp> createState() => _HomeBoxAppState();
}

class _HomeBoxAppState extends State<HomeBoxApp> {
  late final AppLocaleController _localeController;
  late final bool _ownsLocaleController;

  @override
  void initState() {
    super.initState();
    _ownsLocaleController = widget.localeController == null;
    _localeController = widget.localeController ?? AppLocaleController();
    if (_ownsLocaleController) unawaited(_localeController.initialize());
  }

  @override
  void dispose() {
    if (_ownsLocaleController) _localeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _localeController,
    builder: (context, _) => MaterialApp(
      title: 'HomeBox',
      locale: Locale(_localeController.language.languageCode),
      supportedLocales: const [Locale('en'), Locale('ru')],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b87)),
        useMaterial3: true,
      ),
      home: HomeBoxDesktopPage(
        deviceIdentityStore: widget.deviceIdentityStore,
        serverConnectionController: widget.serverConnectionController,
        vaultKeyStore: widget.vaultKeyStore,
        syncFolderStore: widget.syncFolderStore,
        cameraPhotoPicker: widget.cameraPhotoPicker,
        biometricAuthenticator: widget.biometricAuthenticator,
        androidFileSaver: widget.androidFileSaver,
        androidFileSharer: widget.androidFileSharer,
        androidSyncFolder: widget.androidSyncFolder,
        localeController: _localeController,
      ),
    ),
  );
}

enum AppSection { files, sync, settings }

String _localized(
  BuildContext context, {
  required String en,
  required String ru,
}) => Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

class HomeBoxDesktopPage extends StatefulWidget {
  const HomeBoxDesktopPage({
    super.key,
    this.deviceIdentityStore,
    this.serverConnectionController,
    this.vaultKeyStore,
    this.syncFolderStore,
    this.cameraPhotoPicker,
    this.biometricAuthenticator,
    this.androidFileSaver,
    this.androidFileSharer,
    this.androidSyncFolder,
    this.localeController,
  });

  final DeviceIdentityStore? deviceIdentityStore;

  // Overridable purely so tests can supply in-memory-backed instances
  // instead of ones backed by real OS secure storage (see widget_test.dart)
  // — matching the same reason deviceIdentityStore above is overridable.
  final ServerConnectionController? serverConnectionController;
  final VaultKeyStore? vaultKeyStore;
  final SyncFolderStore? syncFolderStore;
  final CameraPhotoPicker? cameraPhotoPicker;
  final BiometricAuthenticator? biometricAuthenticator;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;
  final AndroidSyncFolder? androidSyncFolder;
  final AppLocaleController? localeController;

  @override
  State<HomeBoxDesktopPage> createState() => _HomeBoxDesktopPageState();
}

class _HomeBoxDesktopPageState extends State<HomeBoxDesktopPage> {
  late final DeviceIdentityStore _deviceIdentityStore;
  late final DeviceSetupController _deviceSetupController;
  late final DeviceProvisioningController _deviceProvisioningController;
  late final ServerConnectionController _serverConnectionController;
  late final VaultKeyStore _vaultKeyStore;
  late final VaultSetupController _vaultSetupController;
  late final SyncFolderStore _syncFolderStore;
  late final SyncFolderWatcher _syncFolderWatcher;
  late final CameraPhotoPicker _cameraPhotoPicker;
  late final AndroidFileSaver _androidFileSaver;
  late final AndroidFileSharer _androidFileSharer;
  late final AndroidSyncFolder _androidSyncFolder;
  late final WindowsSyncFolder _windowsSyncFolder;
  late final DownloadNotificationController _downloadNotifications;
  late final AppLocaleController _localeController;
  late final bool _ownsLocaleController;
  BiometricAuthenticator? _biometricAuthenticator;
  SyncEngine? _syncEngine;
  FilesController? _filesController;
  SyncFolderMaterializer? _syncFolderMaterializer;
  LocalFolderUploader? _localFolderUploader;
  String? _syncEngineFingerprint;
  bool _rebuildingSyncEngine = false;
  bool _pendingRebuildFingerprint = false;
  bool _syncFolderPassRunning = false;
  Completer<void>? _syncFolderPassDone;
  bool _pendingSyncFolderPass = false;
  bool _pendingLocalSyncFolderChange = false;
  bool _resyncingVault = false;
  bool _resyncRecoveryRequired = false;
  AppSection _section = AppSection.files;
  String? _syncFolder;
  bool _selectingFolder = false;
  String? _recoveredCameraPhotoPath;
  bool _biometricGateReady = false;
  bool _biometricAvailable = false;
  bool _biometricLocked = false;
  bool _biometricAuthenticationInProgress = false;

  @override
  void initState() {
    super.initState();
    _deviceIdentityStore =
        widget.deviceIdentityStore ?? DeviceIdentityStore.platform();
    _deviceSetupController = DeviceSetupController(_deviceIdentityStore);
    _serverConnectionController =
        widget.serverConnectionController ??
        ServerConnectionController(deviceIdentityStore: _deviceIdentityStore);
    _vaultKeyStore = widget.vaultKeyStore ?? VaultKeyStore();
    _vaultSetupController = VaultSetupController(_vaultKeyStore);
    _deviceProvisioningController = DeviceProvisioningController(
      deviceIdentityStore: _deviceIdentityStore,
      vaultKeyStore: _vaultKeyStore,
      serverConnection: _serverConnectionController,
    );
    _syncFolderStore = widget.syncFolderStore ?? SyncFolderStore();
    _syncFolderWatcher = SyncFolderWatcher(
      onChange: () => _runSyncFolderPass(localChange: true),
    );
    _cameraPhotoPicker =
        widget.cameraPhotoPicker ?? ImagePickerCameraPhotoPicker();
    _androidFileSaver =
        widget.androidFileSaver ?? MethodChannelAndroidFileSaver();
    _androidFileSharer =
        widget.androidFileSharer ?? MethodChannelAndroidFileSharer();
    _androidSyncFolder =
        widget.androidSyncFolder ?? MethodChannelAndroidSyncFolder();
    _downloadNotifications = DownloadNotificationController();
    _windowsSyncFolder = WindowsSyncFolder();
    _ownsLocaleController = widget.localeController == null;
    _localeController = widget.localeController ?? AppLocaleController();
    if (_ownsLocaleController) unawaited(_localeController.initialize());
    if (supportsBiometricAppLock(defaultTargetPlatform)) {
      _biometricAuthenticator =
          widget.biometricAuthenticator ?? LocalAuthBiometricAuthenticator();
      unawaited(_initializeBiometricGate());
    } else {
      _biometricGateReady = true;
    }
    unawaited(_deviceSetupController.initialize());
    unawaited(_initializeServerConnection());
    unawaited(_vaultSetupController.initialize());
    unawaited(_loadSyncFolder());
    if (supportsCameraCapture(defaultTargetPlatform)) {
      unawaited(_recoverLostCameraPhoto());
    }
    // Whenever the connection or the vault reaches a state where files
    // might actually be listable, refresh — cheap no-ops otherwise (see
    // FilesController._requireContext).
    _serverConnectionController.addListener(_onServerConnectionChanged);
    _vaultSetupController.addListener(_maybeRefreshFiles);
  }

  Future<void> _initializeServerConnection() async {
    await _serverConnectionController.initialize();
    await _rebuildSyncEngineForCurrentServer();
  }

  Future<void> _loadSyncFolder() async {
    final saved = await _syncFolderStore.load();
    if (!mounted || saved == null) return;
    setState(() => _syncFolder = saved);
    unawaited(_windowsSyncFolder.setSelectedFolder(saved));
    if (defaultTargetPlatform != TargetPlatform.android &&
        _syncEngine?.isPaused != true) {
      _syncFolderWatcher.start(saved);
    }
    unawaited(_runSyncFolderPass());
  }

  void _onServerConnectionChanged() {
    unawaited(_deviceSetupController.initialize());
    unawaited(_rebuildSyncEngineForCurrentServer());
    _maybeRefreshFiles();
  }

  /// [SyncEngine] owns a local database scoped by the pinned server's
  /// fingerprint (see [LocalDatabase.open]), so a new one — and a matching
  /// [FilesController] — must be built whenever that fingerprint changes
  /// (first connection, or connecting to a different server after
  /// [ServerConnectionController.forgetServer]). Idempotent: a no-op call
  /// when nothing has changed. Re-entrant calls (e.g. a rapid
  /// forget-then-reconnect before the first rebuild finishes) are not
  /// dropped: each waits for the in-flight rebuild, then re-checks the
  /// fingerprint and rebuilds again if it has since moved on.
  Future<void> _rebuildSyncEngineForCurrentServer() async {
    if (_rebuildingSyncEngine) {
      _pendingRebuildFingerprint = true;
      return;
    }
    final fingerprint = _serverConnectionController.server?.fingerprint;
    if (fingerprint == _syncEngineFingerprint) return;
    _rebuildingSyncEngine = true;
    try {
      final oldFiles = _filesController;
      final oldEngine = _syncEngine;
      final oldMaterializer = _syncFolderMaterializer;
      final oldUploader = _localFolderUploader;
      if (mounted) {
        setState(() {
          _filesController = null;
          _syncEngine = null;
          _syncFolderMaterializer = null;
          _localFolderUploader = null;
        });
      } else {
        _filesController = null;
        _syncEngine = null;
        _syncFolderMaterializer = null;
        _localFolderUploader = null;
      }
      oldFiles?.dispose();
      oldMaterializer?.dispose();
      oldUploader?.dispose();
      oldEngine?.dispose(); // also closes its LocalDatabase.
      _syncEngineFingerprint = fingerprint;
      if (fingerprint != null) {
        final localDatabase = await LocalDatabase.open(fingerprint);
        final engine = SyncEngine(
          serverConnection: _serverConnectionController,
          localDatabase: localDatabase,
        );
        final files = FilesController(
          serverConnection: _serverConnectionController,
          vaultKeyStore: _vaultKeyStore,
          syncEngine: engine,
        );
        final materializer = SyncFolderMaterializer(
          serverConnection: _serverConnectionController,
          vaultKeyStore: _vaultKeyStore,
          syncEngine: engine,
          androidSyncFolder: _androidSyncFolder,
          onFileMaterialized: _showDownloadCompletionNotification,
        );
        final uploader = LocalFolderUploader(
          serverConnection: _serverConnectionController,
          vaultKeyStore: _vaultKeyStore,
          syncEngine: engine,
        );
        if (!mounted) {
          files.dispose();
          materializer.dispose();
          uploader.dispose();
          engine.dispose();
          return;
        }
        setState(() {
          _syncEngine = engine;
          _filesController = files;
          _syncFolderMaterializer = materializer;
          _localFolderUploader = uploader;
        });
        engine.addListener(_onSyncEngineSettled);
        engine.start();
        _maybeRefreshFiles();
        unawaited(_uploadRecoveredCameraPhotoIfReady());
        unawaited(_runSyncFolderPass());
      }
    } finally {
      _rebuildingSyncEngine = false;
    }
    if (_pendingRebuildFingerprint) {
      _pendingRebuildFingerprint = false;
      await _rebuildSyncEngineForCurrentServer();
    }
  }

  void _maybeRefreshFiles() {
    final files = _filesController;
    if (files != null &&
        _serverConnectionController.status ==
            ServerConnectionStatus.authenticated &&
        _vaultSetupController.status == VaultSetupStatus.ready) {
      unawaited(files.refresh());
      unawaited(_uploadRecoveredCameraPhotoIfReady());
    }
  }

  Future<void> _onVaultProvisioned() async {
    await _vaultSetupController.initialize();
    await _syncEngine?.runOnce();
    _maybeRefreshFiles();
  }

  Future<void> _recoverLostCameraPhoto() async {
    try {
      final path = await _cameraPhotoPicker.recoverLostPhoto();
      if (path == null || !mounted) return;
      _recoveredCameraPhotoPath = path;
      unawaited(_uploadRecoveredCameraPhotoIfReady());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('HomeBox could not recover the captured photo.'),
          ),
        );
      }
    }
  }

  Future<void> _capturePhoto() async {
    try {
      final path = await _cameraPhotoPicker.capturePhoto();
      if (path == null) return;
      await _uploadCameraPhoto(path, recovered: false);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('HomeBox could not open the camera.')),
        );
      }
    }
  }

  Future<void> _uploadRecoveredCameraPhotoIfReady() async {
    final path = _recoveredCameraPhotoPath;
    if (path == null ||
        _serverConnectionController.status !=
            ServerConnectionStatus.authenticated ||
        _vaultSetupController.status != VaultSetupStatus.ready ||
        _filesController == null) {
      return;
    }
    _recoveredCameraPhotoPath = null;
    await _uploadCameraPhoto(path, recovered: true);
  }

  Future<void> _uploadCameraPhoto(
    String path, {
    required bool recovered,
  }) async {
    final files = _filesController;
    if (files == null) return;
    final uploaded = await files.uploadFile(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          uploaded
              ? (recovered
                    ? 'Recovered camera photo encrypted and uploaded.'
                    : 'Camera photo encrypted and uploaded.')
              : (files.errorMessage ?? 'Could not upload the camera photo.'),
        ),
      ),
    );
  }

  /// Re-mirrors the sync folder once a background sync pass settles, so
  /// changes made from another device show up on disk without the user
  /// having to reselect the folder.
  void _onSyncEngineSettled() {
    if (_syncEngine?.status == SyncStatus.idle) unawaited(_runSyncFolderPass());
  }

  /// Downloads pulled changes to disk, then uploads local edits — always in
  /// that order, and never overlapping with another call to this method,
  /// since [LocalFolderUploader] relies on every pull having already been
  /// fully materialized to tell "not downloaded yet" apart from "the user
  /// deleted this" (see its class doc comment). A call that arrives while
  /// one is already running is not dropped: it is coalesced into a single
  /// follow-up pass once the current one finishes.
  /// A local filesystem event must upload first: pulling first would recreate
  /// a directory the user just deleted before the uploader can observe it.
  Future<void> _runSyncFolderPass({bool localChange = false}) async {
    final folder = _syncFolder;
    final engine = _syncEngine;
    final materializer = _syncFolderMaterializer;
    final uploader = _localFolderUploader;
    if (folder == null ||
        engine == null ||
        engine.isPaused ||
        materializer == null ||
        uploader == null ||
        _resyncingVault ||
        _resyncRecoveryRequired) {
      return;
    }
    if (_syncFolderPassRunning) {
      _pendingSyncFolderPass = true;
      _pendingLocalSyncFolderChange |= localChange;
      return;
    }
    _syncFolderPassRunning = true;
    final passDone = Completer<void>();
    _syncFolderPassDone = passDone;
    try {
      if (localChange && defaultTargetPlatform != TargetPlatform.android) {
        await uploader.scan(folder);
      }
      await materializer.materialize(folder);
      // SAF has no reliable recursive filesystem event stream, so Android
      // mirrors server changes to the selected folder but does not watch it.
      if (!localChange && defaultTargetPlatform != TargetPlatform.android) {
        await uploader.scan(folder);
      }
    } finally {
      _syncFolderPassRunning = false;
      _syncFolderPassDone = null;
      passDone.complete();
    }
    if (_pendingSyncFolderPass) {
      _pendingSyncFolderPass = false;
      final pendingLocalChange = _pendingLocalSyncFolderChange;
      _pendingLocalSyncFolderChange = false;
      await _runSyncFolderPass(localChange: pendingLocalChange);
    }
  }

  /// Drives Android's pull-to-refresh gesture on the Files page. Awaits
  /// [SyncEngine.runOnce] — which, even if a periodic pass was already in
  /// flight when the user pulled, now waits for that same pass rather than
  /// no-op'ing (see its doc comment) — then explicitly refreshes the Files
  /// listing too: [SyncEngine]'s own change notification already triggers
  /// [FilesController] to refresh itself, but only as an un-awaited
  /// fire-and-forget call, which isn't enough to guarantee the list has
  /// actually finished updating by the time this method's caller (the
  /// RefreshIndicator) dismisses its spinner. The resulting second refresh
  /// pass is a small amount of redundant local decrypt work, traded
  /// deliberately for that guarantee.
  Future<void> _refreshFromServer() async {
    await _syncEngine?.runOnce();
    await _filesController?.refresh();
  }

  void _toggleSyncPause() {
    final engine = _syncEngine;
    if (engine == null) return;
    if (engine.isPaused) {
      if (_resyncRecoveryRequired) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Resync did not finish. Retry Resync before resuming normal synchronization.',
            ),
          ),
        );
        return;
      }
      engine.resume();
      final folder = _syncFolder;
      if (folder != null && defaultTargetPlatform != TargetPlatform.android) {
        _syncFolderWatcher.start(folder);
      }
      unawaited(_runSyncFolderPass());
    } else {
      _syncFolderWatcher.stop();
      engine.pause();
    }
  }

  Future<void> _confirmAndResyncVault() async {
    final folder = _syncFolder;
    final engine = _syncEngine;
    final uploader = _localFolderUploader;
    if (folder == null || engine == null || uploader == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rebuild Vault from local folder?'),
        content: const Text(
          'All current files and folders in the server Vault will be moved to Trash. '
          'The selected local sync folder will then be uploaded as a new Vault.\n\n'
          'Do not edit the folder or use another HomeBox device until Resync finishes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-resync-vault'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Resync'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final wasPaused = engine.isPaused;
    setState(() {
      _resyncingVault = true;
      _resyncRecoveryRequired = false;
    });
    _syncFolderWatcher.stop();
    final activeFolderPass = _syncFolderPassDone;
    if (activeFolderPass != null) await activeFolderPass.future;
    await engine.runOnce();
    if (!mounted) return;
    engine.pause();

    final succeeded = await uploader.resyncFromLocalFolder(folder);
    if (!mounted) return;
    final requiresRecovery = !succeeded && uploader.resyncRequiresRecovery;
    setState(() {
      _resyncingVault = false;
      _resyncRecoveryRequired = requiresRecovery;
    });
    if (succeeded || !requiresRecovery) {
      if (!wasPaused) {
        engine.resume();
        if (defaultTargetPlatform != TargetPlatform.android) {
          _syncFolderWatcher.start(folder);
        }
        await engine.runOnce();
      }
      if (succeeded) await _filesController?.refresh();
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          succeeded
              ? 'Resync completed. The local folder is now the active Vault.'
              : requiresRecovery
              ? 'Resync stopped safely and normal sync remains paused. Fix the issue and retry Resync: ${uploader.errorMessage ?? 'unknown error'}'
              : 'Resync could not start: ${uploader.errorMessage ?? 'unknown error'}',
        ),
      ),
    );
  }

  /// Runs once, from [initState] — see [BiometricAuthenticator]'s doc
  /// comment for why this is not repeated on every app resume.
  Future<void> _initializeBiometricGate() async {
    final authenticator = _biometricAuthenticator;
    if (authenticator == null) return;
    var available = false;
    try {
      available = await authenticator.isAvailable();
    } catch (_) {
      // Authentication is an optional Android capability. A platform error
      // must not make the rest of the local client inaccessible.
    }
    if (!mounted) return;
    setState(() {
      _biometricGateReady = true;
      _biometricAvailable = available;
      _biometricLocked = available;
    });
    if (available) unawaited(_unlockWithBiometrics());
  }

  Future<void> _unlockWithBiometrics() async {
    final authenticator = _biometricAuthenticator;
    if (authenticator == null ||
        !_biometricGateReady ||
        !_biometricAvailable ||
        !_biometricLocked ||
        _biometricAuthenticationInProgress) {
      return;
    }
    setState(() => _biometricAuthenticationInProgress = true);
    var authenticated = false;
    try {
      authenticated = await authenticator.authenticate();
    } catch (_) {
      // The lock screen offers an explicit retry after a cancelled or failed
      // prompt, while leaving encrypted content hidden.
    } finally {
      _biometricAuthenticationInProgress = false;
    }
    if (!mounted) return;
    if (authenticated) {
      setState(() => _biometricLocked = false);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _serverConnectionController.removeListener(_onServerConnectionChanged);
    _vaultSetupController.removeListener(_maybeRefreshFiles);
    _filesController?.dispose();
    _syncFolderMaterializer?.dispose();
    _localFolderUploader?.dispose();
    _downloadNotifications.dispose();
    _syncFolderWatcher.dispose();
    _syncEngine?.dispose();
    _vaultSetupController.dispose();
    _deviceProvisioningController.dispose();
    _deviceSetupController.dispose();
    _serverConnectionController.dispose();
    if (_ownsLocaleController) _localeController.dispose();
    super.dispose();
  }

  Future<void> _selectSyncFolder() async {
    setState(() => _selectingFolder = true);
    try {
      final folder = defaultTargetPlatform == TargetPlatform.android
          ? await _androidSyncFolder.selectFolder()
          : await getDirectoryPath(confirmButtonText: 'Use as HomeBox folder');
      if (!mounted || folder == null) return;
      setState(() => _syncFolder = folder);
      await _syncFolderStore.save(folder);
      unawaited(_windowsSyncFolder.setSelectedFolder(folder));
      if (defaultTargetPlatform != TargetPlatform.android &&
          _syncEngine?.isPaused != true) {
        _syncFolderWatcher.start(folder);
      }
      unawaited(_runSyncFolderPass());
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('HomeBox could not open the folder picker.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _selectingFolder = false);
    }
  }

  Future<void> _openSyncFolder() async {
    if (await _windowsSyncFolder.open() || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('HomeBox could not open the sync folder.')),
    );
  }

  /// The header's transfer/sync/vault status group, shared by the narrow
  /// AppBar and the wide desktop header. This wrapper listens to every source
  /// that can show a transient transfer, so those indicators are absent — and
  /// reserve no [spacing] — while idle. [_SyncStatusChip] independently also
  /// listens to the local-folder materializer, because the vault is not up to
  /// date from the user's perspective until its files reach that folder.
  Widget _headerStatusIndicators({
    required bool dense,
    required double spacing,
  }) {
    final filesController = _filesController;
    final materializer = _syncFolderMaterializer;
    final uploader = _localFolderUploader;
    final listenables = <Listenable>[
      ?filesController,
      ?materializer,
      ?uploader,
    ];
    if (listenables.isEmpty) {
      return _buildHeaderStatusIndicators(
        dense: dense,
        spacing: spacing,
        showTransfer: false,
        showSyncFolderTransfer: false,
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) => _buildHeaderStatusIndicators(
        dense: dense,
        spacing: spacing,
        showTransfer: filesController?.busy ?? false,
        showSyncFolderTransfer:
            materializer?.transferProgress != null ||
            uploader?.transferProgress != null,
      ),
    );
  }

  Widget _buildHeaderStatusIndicators({
    required bool dense,
    required double spacing,
    required bool showTransfer,
    required bool showSyncFolderTransfer,
  }) {
    final children = [
      if (showTransfer)
        _TransferProgressIndicator(
          filesController: _filesController,
          dense: dense,
        ),
      if (showSyncFolderTransfer)
        _SyncFolderTransferProgressIndicator(
          materializer: _syncFolderMaterializer,
          uploader: _localFolderUploader,
          dense: dense,
        ),
      _SyncStatusChip(
        syncEngine: _syncEngine,
        syncFolderMaterializer: _syncFolderMaterializer,
        dense: dense,
      ),
      _VaultStateChip(controller: _vaultSetupController),
    ];
    return dense
        ? Row(
            mainAxisSize: MainAxisSize.min,
            spacing: spacing,
            children: children,
          )
        : Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: spacing,
            runSpacing: 8,
            children: children,
          );
  }

  @override
  Widget build(BuildContext context) {
    if (!_biometricGateReady) {
      return const _BiometricGateLoadingScreen();
    }
    if (_biometricLocked) {
      return _BiometricLockScreen(
        authenticating: _biometricAuthenticationInProgress,
        onUnlock: _unlockWithBiometrics,
      );
    }
    final wideLayout = MediaQuery.sizeOf(context).width >= 720;
    final content = _SectionContent(
      section: _section,
      syncFolder: _syncFolder,
      selectingFolder: _selectingFolder,
      onSelectSyncFolder: _selectSyncFolder,
      onOpenSyncFolder: defaultTargetPlatform == TargetPlatform.windows
          ? _openSyncFolder
          : null,
      deviceSetupController: _deviceSetupController,
      deviceProvisioningController: _deviceProvisioningController,
      serverConnectionController: _serverConnectionController,
      vaultSetupController: _vaultSetupController,
      onVaultProvisioned: _onVaultProvisioned,
      filesController: _filesController,
      syncEngine: _syncEngine,
      syncFolderMaterializer: _syncFolderMaterializer,
      localFolderUploader: _localFolderUploader,
      syncFolderWatcher: _syncFolderWatcher,
      onToggleSyncPause: _toggleSyncPause,
      onResyncVault: _confirmAndResyncVault,
      resyncingVault: _resyncingVault,
      onCapturePhoto: supportsCameraCapture(defaultTargetPlatform)
          ? _capturePhoto
          : null,
      androidFileSaver: supportsAndroidSaveDialog(defaultTargetPlatform)
          ? _androidFileSaver
          : null,
      androidFileSharer: supportsAndroidFileSharing(defaultTargetPlatform)
          ? _androidFileSharer
          : null,
      androidSyncFolder: defaultTargetPlatform == TargetPlatform.android
          ? _androidSyncFolder
          : null,
      localeController: _localeController,
      onPullToRefresh: defaultTargetPlatform == TargetPlatform.android
          ? _refreshFromServer
          : null,
      onDownloadCompleted: _showDownloadCompletionNotification,
    );
    if (!wideLayout) {
      return _withDownloadNotifications(
        Scaffold(
          appBar: AppBar(
            title: const Text('HomeBox'),
            actions: [
              // Scrolls instead of overflowing: three status indicators can
              // together be wider than a narrow phone's AppBar leaves room
              // for once a long sync-error tooltip or the full vault chip is
              // in the mix.
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _headerStatusIndicators(dense: true, spacing: 8),
                ),
              ),
            ],
          ),
          body: content,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _section.index,
            onDestinationSelected: (index) =>
                setState(() => _section = AppSection.values[index]),
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: _localized(context, en: 'Files', ru: 'Файлы'),
              ),
              NavigationDestination(
                icon: Icon(Icons.sync_outlined),
                selectedIcon: Icon(Icons.sync),
                label: _localized(context, en: 'Sync', ru: 'Синхронизация'),
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: _localized(context, en: 'Settings', ru: 'Настройки'),
              ),
            ],
          ),
        ),
      );
    }
    return _withDownloadNotifications(
      Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              NavigationRail(
                selectedIndex: _section.index,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (index) =>
                    setState(() => _section = AppSection.values[index]),
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Icon(Icons.inventory_2_outlined, size: 32),
                ),
                destinations: [
                  NavigationRailDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder),
                    label: Text(_localized(context, en: 'Files', ru: 'Файлы')),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.sync_outlined),
                    selectedIcon: Icon(Icons.sync),
                    label: Text(
                      _localized(context, en: 'Sync', ru: 'Синхронизация'),
                    ),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text(
                      _localized(context, en: 'Settings', ru: 'Настройки'),
                    ),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 20, 32, 8),
                      child: Row(
                        children: [
                          Text(
                            'HomeBox',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _headerStatusIndicators(
                              dense: false,
                              spacing: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(child: content),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDownloadCompletionNotification({
    required String fileName,
    required String location,
  }) {
    _downloadNotifications.show(fileName: fileName, location: location);
  }

  Widget _withDownloadNotifications(Widget child) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      _DownloadNotificationStack(controller: _downloadNotifications),
    ],
  );
}

/// An overlay rather than a [SnackBar] queue, so separate completed
/// downloads remain visible together and each can be dismissed on its own.
final class _DownloadNotificationStack extends StatelessWidget {
  const _DownloadNotificationStack({required this.controller});

  final DownloadNotificationController controller;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final notifications = controller.notifications;
        if (notifications.isEmpty) return const SizedBox.shrink();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: notifications
                      .map(
                        (notification) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _DownloadCompletionCard(
                            notification: notification,
                            onDismiss: () =>
                                controller.dismiss(notification.id),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

final class _DownloadCompletionCard extends StatelessWidget {
  const _DownloadCompletionCard({
    required this.notification,
    required this.onDismiss,
  });

  final DownloadCompletionNotification notification;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final completedLabel = _localized(
      context,
      en: 'Download complete',
      ru: 'Загрузка завершена',
    );
    final savedToLabel = _localized(context, en: 'Saved to', ru: 'Сохранено в');
    final dismissLabel = _localized(
      context,
      en: 'Dismiss download notification',
      ru: 'Закрыть уведомление о загрузке',
    );
    return Semantics(
      container: true,
      label:
          '$completedLabel: ${notification.fileName}. '
          '$savedToLabel ${notification.location}.',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              const Icon(Icons.download_done_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(completedLabel, style: textTheme.titleSmall),
                    Text(
                      notification.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium,
                    ),
                    Text(
                      '$savedToLabel ${notification.location}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
                tooltip: dismissLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _BiometricGateLoadingScreen extends StatelessWidget {
  const _BiometricGateLoadingScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

final class _BiometricLockScreen extends StatelessWidget {
  const _BiometricLockScreen({
    required this.authenticating,
    required this.onUnlock,
  });

  final bool authenticating;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fingerprint, size: 72),
              const SizedBox(height: 20),
              Text(
                'HomeBox locked',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Use your enrolled biometric to access encrypted files.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: authenticating ? null : onUnlock,
                icon: const Icon(Icons.fingerprint),
                label: Text(authenticating ? 'Checking…' : 'Unlock'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Icon-only (no "locked"/"unlocked" text pill): the open/closed lock shape
/// already conveys the state, and the header has several of these status
/// indicators competing for space. The fuller explanation of what "locked"
/// means here still lives in Settings, next to vault setup itself.
class _VaultStateChip extends StatelessWidget {
  const _VaultStateChip({required this.controller});

  final VaultSetupController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final ready = controller.status == VaultSetupStatus.ready;
      return _headerStatusIndicator(
        icon: ready ? Icons.lock_open_outlined : Icons.lock_outline,
        label: ready ? 'Vault unlocked' : 'Vault locked',
        tooltip: ready
            ? 'This vault was created on this device. A trusted device or Recovery Secret is required on any other device.'
            : 'Create or restore this account\'s vault in Settings to unlock E2EE data.',
        dense: true,
      );
    },
  );
}

/// A [Chip] mirroring [label] when [dense] is false (used in the roomy
/// desktop header), or a bare tooltipped icon when true (used in the
/// narrow/Android AppBar, where three side-by-side chips would overflow).
Widget _headerStatusIndicator({
  required IconData icon,
  required String label,
  String? tooltip,
  Color? color,
  required bool dense,
}) {
  if (dense) {
    return Tooltip(
      message: tooltip ?? label,
      child: Icon(icon, size: 20, color: color),
    );
  }
  return Tooltip(
    message: tooltip ?? label,
    child: Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
    ),
  );
}

/// Duplicates the Sync page's status (spec: offline/up to date/syncing/…)
/// in the header, so it is visible from any section without switching tabs.
class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip({
    required this.syncEngine,
    required this.syncFolderMaterializer,
    this.dense = false,
  });

  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final engine = syncEngine;
    if (engine == null) {
      // Matches the label the Sync page itself shows for this same
      // condition (no engine yet — vault locked/not provisioned).
      return _headerStatusIndicator(
        icon: Icons.pause_circle_outline,
        label: 'Sync paused',
        dense: dense,
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([engine, ?syncFolderMaterializer]),
      builder: (context, _) {
        final (icon, label, color, tooltip) = _effectiveSyncStatusPresentation(
          engine: engine,
          materializer: syncFolderMaterializer,
        );
        return _headerStatusIndicator(
          icon: icon,
          label: label,
          tooltip: tooltip,
          color: color,
          dense: dense,
        );
      },
    );
  }
}

/// The header counterpart of the Files page's upload/download percentage —
/// visible from any section, not just while Files is open. Renders nothing
/// while no transfer is in progress.
class _TransferProgressIndicator extends StatelessWidget {
  const _TransferProgressIndicator({
    required this.filesController,
    this.dense = false,
  });

  final FilesController? filesController;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final controller = filesController;
    if (controller == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.busy) return const SizedBox.shrink();
        final percent = _transferProgressPercent(controller);
        final label = _transferProgressLabel(
          controller.transferDirection,
          percent,
        );
        // An arrow (direction) plus the percent itself, rather than a bare
        // spinner: a spinner alone doesn't say whether HomeBox is sending
        // or receiving, or how far along it is, at a glance in the header.
        final directionIcon = switch (controller.transferDirection) {
          FileTransferDirection.upload => Icons.arrow_upward,
          FileTransferDirection.download => Icons.arrow_downward,
          null => Icons.sync,
        };
        final content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(directionIcon, size: dense ? 18 : 16),
            const SizedBox(width: 2),
            Text('$percent%'),
          ],
        );
        if (dense) return Tooltip(message: label, child: content);
        return Tooltip(
          message: label,
          child: Chip(
            avatar: Icon(directionIcon, size: 18),
            label: Text('$percent%'),
          ),
        );
      },
    );
  }
}

/// Compact local-folder transfer progress for the global header. Its parent
/// listens to both sources and creates this widget only while a file is
/// actually moving, so the idle header stays compact.
class _SyncFolderTransferProgressIndicator extends StatelessWidget {
  const _SyncFolderTransferProgressIndicator({
    required this.materializer,
    required this.uploader,
    this.dense = false,
  });

  final SyncFolderMaterializer? materializer;
  final LocalFolderUploader? uploader;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final downloadProgress = materializer?.transferProgress;
    final uploadProgress = uploader?.transferProgress;
    final (direction, fileName, progress, icon) = downloadProgress != null
        ? (
            'Downloading',
            materializer?.activeFileName ?? 'file',
            downloadProgress,
            Icons.arrow_downward,
          )
        : uploadProgress != null
        ? (
            'Uploading',
            uploader?.activeFileName ?? 'file',
            uploadProgress,
            Icons.arrow_upward,
          )
        : ('Syncing', 'file', 0.0, Icons.sync);
    final percent = (progress * 100).round().clamp(0, 100);
    final tooltip = '$direction $fileName — $percent%';
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: dense ? 18 : 20,
          child: CircularProgressIndicator(strokeWidth: 2, value: progress),
        ),
        const SizedBox(width: 4),
        Icon(icon, size: dense ? 16 : 18),
        const SizedBox(width: 2),
        Text('$percent%'),
      ],
    );
    if (dense) return Tooltip(message: tooltip, child: content);
    return Tooltip(
      message: tooltip,
      child: Chip(avatar: Icon(icon, size: 18), label: Text('$percent%')),
    );
  }
}

class _SectionContent extends StatelessWidget {
  const _SectionContent({
    required this.section,
    required this.syncFolder,
    required this.selectingFolder,
    required this.onSelectSyncFolder,
    required this.onOpenSyncFolder,
    required this.deviceSetupController,
    required this.deviceProvisioningController,
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.onVaultProvisioned,
    required this.filesController,
    required this.syncEngine,
    required this.syncFolderMaterializer,
    required this.localFolderUploader,
    required this.syncFolderWatcher,
    required this.onToggleSyncPause,
    required this.onResyncVault,
    required this.resyncingVault,
    required this.onCapturePhoto,
    required this.androidFileSaver,
    required this.androidFileSharer,
    required this.androidSyncFolder,
    required this.localeController,
    required this.onPullToRefresh,
    required this.onDownloadCompleted,
  });

  final AppSection section;
  final String? syncFolder;
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;
  final Future<void> Function()? onOpenSyncFolder;
  final DeviceSetupController deviceSetupController;
  final DeviceProvisioningController deviceProvisioningController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final Future<void> Function() onVaultProvisioned;
  final FilesController? filesController;
  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final LocalFolderUploader? localFolderUploader;
  final SyncFolderWatcher syncFolderWatcher;
  final VoidCallback onToggleSyncPause;
  final Future<void> Function() onResyncVault;
  final bool resyncingVault;
  final Future<void> Function()? onCapturePhoto;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;
  final AndroidSyncFolder? androidSyncFolder;
  final AppLocaleController localeController;
  final Future<void> Function()? onPullToRefresh;
  final void Function({required String fileName, required String location})
  onDownloadCompleted;

  @override
  Widget build(BuildContext context) => switch (section) {
    AppSection.files => _FilesSection(
      controller: filesController,
      onCapturePhoto: onCapturePhoto,
      androidFileSaver: androidFileSaver,
      androidFileSharer: androidFileSharer,
      syncFolder: syncFolder,
      androidSyncFolder: androidSyncFolder,
      onPullToRefresh: onPullToRefresh,
      onDownloadCompleted: onDownloadCompleted,
    ),
    AppSection.sync => _SyncSection(
      syncFolder: syncFolder,
      onSelectSyncFolder: onSelectSyncFolder,
      onOpenSyncFolder: onOpenSyncFolder,
      syncEngine: syncEngine,
      syncFolderMaterializer: syncFolderMaterializer,
      localFolderUploader: localFolderUploader,
      syncFolderWatcher: syncFolderWatcher,
      onToggleSyncPause: onToggleSyncPause,
      onResyncVault: onResyncVault,
      resyncingVault: resyncingVault,
    ),
    AppSection.settings => _SettingsSection(
      deviceSetupController: deviceSetupController,
      deviceProvisioningController: deviceProvisioningController,
      serverConnectionController: serverConnectionController,
      vaultSetupController: vaultSetupController,
      onVaultProvisioned: onVaultProvisioned,
      localeController: localeController,
    ),
  };
}

/// The server-side icon/label used as the baseline by
/// [_effectiveSyncStatusPresentation].
(IconData icon, String label) _syncStatusPresentation(SyncStatus status) =>
    switch (status) {
      SyncStatus.idle => (Icons.check_circle_outline, 'Up to date'),
      SyncStatus.syncing => (Icons.sync, 'Syncing…'),
      SyncStatus.paused => (Icons.pause_circle_outline, 'Sync paused'),
      SyncStatus.offline => (Icons.cloud_off_outlined, 'Offline'),
      SyncStatus.error => (Icons.error_outline, 'Sync error'),
    };

/// Resolves the status the user sees for the whole synchronization flow. A
/// completed server pull is not "up to date" while its changed files are
/// still being written into the selected local sync folder.
(IconData icon, String label, Color? color, String? tooltip)
_effectiveSyncStatusPresentation({
  required SyncEngine engine,
  SyncFolderMaterializer? materializer,
}) {
  final base = _syncStatusPresentation(engine.status);
  return switch ((engine.status, materializer?.status)) {
    (SyncStatus.error, _) => (
      Icons.error_outline,
      'Sync error',
      Colors.red,
      engine.errorMessage,
    ),
    (_, SyncFolderStatus.error) => (
      Icons.error_outline,
      'Folder sync error',
      Colors.red,
      materializer?.errorMessage,
    ),
    (_, SyncFolderStatus.materializing) => (
      Icons.download_outlined,
      'Writing files…',
      null,
      null,
    ),
    _ => (
      base.$1,
      base.$2,
      engine.status == SyncStatus.idle ? Colors.green : null,
      null,
    ),
  };
}

/// The rounded 0-100 percent for [FilesController.progress] — shared so the
/// Files page's own transfer row and the header's [_TransferProgressIndicator]
/// can never drift into different rounding/clamping.
int _transferProgressPercent(FilesController controller) =>
    ((controller.progress ?? 0) * 100).round().clamp(0, 100);

String _transferProgressLabel(FileTransferDirection? direction, int percent) =>
    switch (direction) {
      FileTransferDirection.upload => 'Upload progress $percent percent',
      FileTransferDirection.download => 'Download progress $percent percent',
      null => 'Transfer progress $percent percent',
    };

/// "size • Updated relative time" for a file's [ListTile] subtitle.
/// [FileEntry.metadata.plaintextSize] is null for files uploaded before that
/// field existed, so the size segment is simply omitted for those. Uses
/// [LocalNode.updatedAt] rather than [LocalNode.createdAt] so replacing a
/// file's content (spec: "Replace content…") is reflected here — the server
/// bumps `updated_at` on every node mutation, including a completed upload.
String _fileEntrySubtitle(FileEntry entry) {
  final parts = <String>[];
  final size = entry.metadata.plaintextSize;
  if (size != null) parts.add(_formatFileSize(size));
  parts.add('Updated ${_formatRelativeTime(entry.node.updatedAt)}');
  return parts.join(' • ');
}

String _fileSortLabel(FileListSort sort) => switch (sort) {
  FileListSort.name => 'Name',
  FileListSort.extension => 'Extension',
  FileListSort.updatedAt => 'Date updated',
};

String _formatFileSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final precision = unitIndex == 0 ? 0 : 1;
  return '${size.toStringAsFixed(precision)} ${units[unitIndex]}';
}

String _formatRelativeTime(DateTime utc) {
  final elapsed = DateTime.now().toUtc().difference(utc.toUtc());
  final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  if (seconds < 60) return _relativeTimeUnit(seconds, 'second');
  final minutes = seconds ~/ 60;
  if (minutes < 60) return _relativeTimeUnit(minutes, 'minute');
  final hours = minutes ~/ 60;
  if (hours < 24) return _relativeTimeUnit(hours, 'hour');
  final days = hours ~/ 24;
  if (days < 30) return _relativeTimeUnit(days, 'day');
  final months = days ~/ 30;
  if (months < 12) return _relativeTimeUnit(months, 'month');
  return _relativeTimeUnit(days ~/ 365, 'year');
}

String _relativeTimeUnit(int value, String unit) =>
    '$value $unit${value == 1 ? '' : 's'} ago';

const double _fileListLeadingSize = 44;

const Widget _defaultFileListIcon = SizedBox.square(
  dimension: _fileListLeadingSize,
  child: Icon(Icons.insert_drive_file_outlined, size: _fileListLeadingSize),
);

const Widget _folderListIcon = SizedBox.square(
  dimension: _fileListLeadingSize,
  child: Icon(
    Icons.folder,
    size: _fileListLeadingSize,
    color: Colors.lightBlue,
  ),
);

/// Shows a decrypted, downscaled image thumbnail when it is inexpensive to
/// fetch. All other files, including unsupported image encodings, retain the
/// regular file icon.
class _FileListLeading extends StatelessWidget {
  const _FileListLeading({required this.entry, required this.controller});

  final FileEntry entry;
  final FilesController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.canShowImagePreview(entry)) {
      return _defaultFileListIcon;
    }
    return SizedBox.square(
      dimension: _fileListLeadingSize,
      child: FutureBuilder(
        future: controller.imagePreview(entry),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            return _defaultFileListIcon;
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: 96,
              cacheHeight: 96,
              errorBuilder: (context, error, stackTrace) =>
                  _defaultFileListIcon,
            ),
          );
        },
      ),
    );
  }
}

enum _OverwriteChoice { overwrite, skip, cancel }

Future<_OverwriteChoice> _askOverwrite(
  BuildContext context,
  String fileName,
) async {
  final choice = await showDialog<_OverwriteChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('File already exists'),
      content: Text('"$fileName" already exists in this folder.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.skip),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.overwrite),
          child: const Text('Overwrite'),
        ),
      ],
    ),
  );
  // A dismissed dialog (back button/tap outside) is treated the same as an
  // explicit Cancel — the safer default for a destructive action.
  return choice ?? _OverwriteChoice.cancel;
}

final class _FilesSection extends StatefulWidget {
  const _FilesSection({
    required this.controller,
    required this.onCapturePhoto,
    required this.androidFileSaver,
    required this.androidFileSharer,
    required this.syncFolder,
    required this.androidSyncFolder,
    required this.onPullToRefresh,
    required this.onDownloadCompleted,
  });

  final FilesController? controller;
  final Future<void> Function()? onCapturePhoto;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;
  final String? syncFolder;
  final AndroidSyncFolder? androidSyncFolder;
  final Future<void> Function()? onPullToRefresh;
  final void Function({required String fileName, required String location})
  onDownloadCompleted;

  @override
  State<_FilesSection> createState() => _FilesSectionState();
}

final class _FilesSectionState extends State<_FilesSection> {
  final WindowsSyncFolder _windowsSyncFolder = WindowsSyncFolder();

  @override
  void initState() {
    super.initState();
    unawaited(WindowsFileDrop.listen(_uploadDroppedFiles));
  }

  @override
  void dispose() {
    WindowsFileDrop.stopListening();
    super.dispose();
  }

  Future<void> _createFolder(BuildContext context) async {
    final controller = widget.controller;
    if (controller == null) return;
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final ok = await controller.createFolder(name.trim());
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ?? 'Could not create the folder.',
          ),
        ),
      );
    }
  }

  Future<void> _uploadFiles(BuildContext context) async {
    final controller = widget.controller;
    if (controller == null) return;
    final files = await openFiles();
    if (files.isEmpty || !context.mounted) return;
    await _uploadPathsWithOverwritePrompt(
      context,
      files.map((file) => file.path).toList(growable: false),
    );
  }

  /// Uploads [paths] into the currently open folder, asking before silently
  /// clobbering a same-named file already there: a name already present in
  /// [FilesController.entries] prompts overwrite/skip/cancel, and an
  /// overwrite goes through [FilesController.replaceFileContent] (a new
  /// version of the existing node) rather than creating a duplicate.
  Future<void> _uploadPathsWithOverwritePrompt(
    BuildContext context,
    List<String> paths,
  ) async {
    final controller = widget.controller;
    if (controller == null || paths.isEmpty) return;
    // uploadFiles captures this same folder before awaiting work. Preserve
    // the readable path now too, so a completed upload is copied into the
    // equivalent sync-folder location even if the user navigates meanwhile.
    final syncFolderRelativePath = controller.breadcrumbNames.join('/');
    final toCreate = <String>[];
    final toReplace = <(FileEntry, String)>[];
    for (final path in paths) {
      final name = basenameOfLocalPath(path);
      FileEntry? existing;
      for (final entry in controller.entries) {
        if (!entry.isDirectory && entry.name == name) {
          existing = entry;
          break;
        }
      }
      if (existing == null) {
        toCreate.add(path);
        continue;
      }
      if (!context.mounted) return;
      final choice = await _askOverwrite(context, name);
      if (choice == _OverwriteChoice.cancel) return;
      if (choice == _OverwriteChoice.overwrite) {
        toReplace.add((existing, path));
      }
      // _OverwriteChoice.skip: leave this path out of both lists.
    }

    var succeeded = 0;
    var failed = 0;
    var syncFolderCopyFailures = 0;
    if (toCreate.isNotEmpty) {
      final result = await controller.uploadFiles(toCreate);
      succeeded += result.succeeded;
      failed += result.failed;
      for (final path in result.successfulPaths) {
        if (!await _copyUploadedFileToSyncFolder(
          path,
          syncFolderRelativePath,
        )) {
          syncFolderCopyFailures++;
        }
      }
    }
    for (final (entry, path) in toReplace) {
      if (await controller.replaceFileContent(entry, path)) {
        succeeded++;
        if (!await _copyUploadedFileToSyncFolder(
          path,
          syncFolderRelativePath,
        )) {
          syncFolderCopyFailures++;
        }
      } else {
        failed++;
      }
    }

    if (!context.mounted || (succeeded == 0 && failed == 0)) return;
    var message = switch ((succeeded, failed)) {
      (0, final f) => controller.errorMessage ?? 'Could not upload $f file(s).',
      (final s, 0) => 'Encrypted and uploaded $s file(s).',
      (final s, final f) =>
        'Uploaded $s file(s); $f file(s) could not be uploaded.',
    };
    if (syncFolderCopyFailures > 0) {
      message +=
          ' The sync folder could not be updated for $syncFolderCopyFailures file(s); HomeBox will download them from the server instead.';
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Copies a freshly uploaded Windows file into the matching sync-folder
  /// location. The materializer later verifies its hash before recognizing
  /// the copy, preserving the server as the authoritative source on changes.
  Future<bool> _copyUploadedFileToSyncFolder(
    String sourcePath,
    String relativeParentPath,
  ) async {
    final syncFolder = widget.syncFolder;
    if (defaultTargetPlatform != TargetPlatform.windows || syncFolder == null) {
      return true;
    }
    final source = File(sourcePath);
    final destination = File(
      relativeParentPath.isEmpty
          ? '$syncFolder/${basenameOfLocalPath(sourcePath)}'
          : '$syncFolder/$relativeParentPath/${basenameOfLocalPath(sourcePath)}',
    );
    if (source.absolute.path.toLowerCase() ==
        destination.absolute.path.toLowerCase()) {
      return true;
    }
    try {
      await destination.parent.create(recursive: true);
      await source.copy(destination.path);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _downloadFile(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final saver = widget.androidFileSaver;
    if (saver != null) {
      await _downloadFileWithAndroidSaveDialog(
        context,
        controller,
        saver,
        entry,
      );
      return;
    }
    final destination = await getSaveLocation(suggestedName: entry.name);
    if (destination == null) return;
    final ok = await controller.downloadFile(entry, destination.path);
    if (ok) {
      widget.onDownloadCompleted(
        fileName: entry.name,
        location: destination.path,
      );
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.errorMessage ?? 'Download failed.')),
      );
    }
  }

  Future<void> _shareFile(BuildContext context, FileEntry entry) async {
    final sharer = widget.androidFileSharer;
    if (sharer == null || entry.isDirectory) return;

    try {
      final sharedFile = await _prepareTempFileForHandoff(
        context,
        entry,
        'Could not prepare the file for sharing.',
      );
      if (sharedFile == null) return;
      try {
        await sharer.shareFile(
          sourcePath: sharedFile.path,
          suggestedName: entry.name,
          mimeType: entry.metadata.mimeType,
        );
      } catch (_) {
        await sharedFile.parent.delete(recursive: true);
        rethrow;
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the share sheet.')),
        );
      }
    }
  }

  /// Downloads and decrypts [entry] into a fresh directory under this app's
  /// share cache — the same sandboxed boundary [AndroidFileSharer] verifies
  /// before granting another app a read URI — for hand-off to either the
  /// share sheet ([_shareFile]) or an installed viewer
  /// ([_openOrDownloadFile]). Returns null on failure, having already shown
  /// [failureMessage] (or the controller's own error) and cleaned up.
  Future<File?> _prepareTempFileForHandoff(
    BuildContext context,
    FileEntry entry,
    String failureMessage,
  ) async {
    final controller = widget.controller;
    if (controller == null) return null;
    final tempDir = await getTemporaryDirectory();
    final shareRoot = Directory('${tempDir.path}/homebox_shared');
    await _deleteExpiredSharedFiles(shareRoot);
    final shareDirectory = Directory(
      '${shareRoot.path}/${entry.node.id}_${DateTime.now().microsecondsSinceEpoch}',
    );
    await shareDirectory.create(recursive: true);
    // SensitiveNodeMetadata validates file names, so this is a single safe
    // path component. Keeping the original name helps recipient apps infer
    // the extension in addition to the MIME type supplied separately.
    final sharedFile = File('${shareDirectory.path}/${entry.name}');
    final downloaded = await controller.downloadFile(entry, sharedFile.path);
    if (!downloaded) {
      await shareDirectory.delete(recursive: true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(controller.errorMessage ?? failureMessage)),
        );
      }
      return null;
    }
    return sharedFile;
  }

  Future<void> _deleteExpiredSharedFiles(Directory shareRoot) async {
    if (!await shareRoot.exists()) return;
    final expiresAt = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in shareRoot.list()) {
      try {
        if ((await entity.stat()).modified.isBefore(expiresAt)) {
          await entity.delete(recursive: true);
        }
      } on FileSystemException {
        // A recipient application can still be reading a shared file. Leave
        // it for the next cleanup attempt instead of interrupting that read.
      }
    }
  }

  Future<void> _openOrDownloadFile(
    BuildContext context,
    FileEntry entry,
  ) async {
    final syncFolder = widget.syncFolder;
    final androidSyncFolder = widget.androidSyncFolder;
    final controller = widget.controller;
    final relativePath = controller?.materializedRelativePath(entry.node.id);
    if (syncFolder != null &&
        androidSyncFolder != null &&
        relativePath != null) {
      try {
        final opened = await androidSyncFolder.openFile(
          treeUri: syncFolder,
          relativePath: relativePath,
          mimeType: entry.metadata.mimeType,
        );
        if (opened) return;
      } on PlatformException {
        // If an external app cannot open the mirrored document, fall through
        // to the temp-file open path below.
      }
    }
    if (!context.mounted) return;

    // Not (yet) materialized to a local sync folder, so there is no document
    // to open directly. Download a temp copy — same as _shareFile does for
    // the share sheet — and hand it to an installed viewer via ACTION_VIEW,
    // instead of jumping straight to "Save as" for every unsynced tap.
    final sharer = widget.androidFileSharer;
    if (sharer != null) {
      final tempFile = await _prepareTempFileForHandoff(
        context,
        entry,
        'Could not open the file.',
      );
      if (tempFile == null) return;
      try {
        final opened = await sharer.openFile(
          sourcePath: tempFile.path,
          suggestedName: entry.name,
          mimeType: entry.metadata.mimeType,
        );
        if (opened) return;
      } on PlatformException {
        // No installed app can open this file type; fall back to Save as.
      }
    }

    if (!context.mounted) return;
    await _downloadFile(context, entry);
  }

  Future<void> _openFileLocation(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    final syncFolder = widget.syncFolder;
    final relativePath = controller?.materializedRelativePath(entry.node.id);
    if (defaultTargetPlatform != TargetPlatform.windows ||
        syncFolder == null ||
        relativePath == null) {
      return;
    }

    final opened = await _windowsSyncFolder.openFileLocation(
      '$syncFolder/$relativePath',
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _localized(
              context,
              en: 'HomeBox could not open the file location.',
              ru: 'HomeBox не удалось открыть расположение файла.',
            ),
          ),
        ),
      );
    }
  }

  /// Android's `file_selector` has no save-dialog implementation, so this
  /// decrypts to a private temp file first, then hands that off to the OS
  /// "Save As" picker (defaulting to Downloads) via [AndroidFileSaver] —
  /// which only ever copies already-decrypted bytes, keeping the E2EE
  /// boundary in [FilesController] unchanged.
  Future<void> _downloadFileWithAndroidSaveDialog(
    BuildContext context,
    FilesController controller,
    AndroidFileSaver saver,
    FileEntry entry,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/download_${entry.node.id}');
    final downloaded = await controller.downloadFile(entry, tempFile.path);
    if (!downloaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(controller.errorMessage ?? 'Download failed.'),
          ),
        );
      }
      unawaited(tempFile.delete().catchError((_) => tempFile));
      return;
    }
    try {
      final destination = await saver.saveFile(
        sourcePath: tempFile.path,
        suggestedName: entry.name,
        mimeType: entry.metadata.mimeType,
      );
      if (destination != null) {
        widget.onDownloadCompleted(fileName: entry.name, location: destination);
      }
    } catch (_) {
      // The file was already decrypted successfully at this point — only
      // handing it to the chosen destination failed (e.g. the device ran
      // out of storage), distinct from a decrypt/download failure above.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save to the selected location.'),
          ),
        );
      }
    } finally {
      unawaited(tempFile.delete().catchError((_) => tempFile));
    }
  }

  Future<void> _replaceContent(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final file = await openFile();
    if (file == null) return;
    final ok = await controller.replaceFileContent(entry, file.path);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ?? 'Could not replace the file.',
          ),
        ),
      );
    }
  }

  Future<void> _renameEntry(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final nameController = TextEditingController(text: entry.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == entry.name) {
      return;
    }
    final ok = await controller.renameNode(entry, name.trim());
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.errorMessage ?? 'Could not rename.')),
      );
    }
  }

  Future<void> _deleteEntry(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to trash?'),
        content: Text('"${entry.name}" will be moved to the trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await controller.deleteNode(entry);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.errorMessage ?? 'Could not delete.')),
      );
    }
  }

  Future<void> _uploadDroppedFiles(List<String> paths) async {
    final controller = widget.controller;
    if (controller == null || controller.busy) return;
    await _uploadPathsWithOverwritePrompt(context, paths);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      return const _FilesMessageState(
        icon: Icons.cloud_off_outlined,
        message: 'Connect to a server, sign in, and set up the vault in Settings to see your files.',
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Whichever message/spinner widget a non-list state below renders,
        // it has no Scrollable of its own, so pull-to-refresh (below) would
        // have nothing to detect the drag gesture against — wrapping it in
        // an always-scrollable, viewport-height ListView fixes that without
        // changing how it looks.
        Widget scrollableMessage(Widget child) => LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [SizedBox(height: constraints.maxHeight, child: child)],
          ),
        );
        final Widget body;
        if (controller.status == FilesStatus.idle) {
          body = scrollableMessage(
            const _FilesMessageState(
              icon: Icons.cloud_off_outlined,
              message: 'Connect to a server, sign in, and set up the vault in Settings to see your files.',
            ),
          );
        } else if (controller.status == FilesStatus.failed) {
          body = scrollableMessage(
            _FilesMessageState(
              icon: Icons.error_outline,
              message: controller.errorMessage ?? 'Files are unavailable.',
            ),
          );
        } else if (controller.status == FilesStatus.loading &&
            controller.entries.isEmpty) {
          body = scrollableMessage(
            const Center(child: CircularProgressIndicator()),
          );
        } else if (controller.entries.isEmpty) {
          body = scrollableMessage(
            const _FilesMessageState(
              icon: Icons.folder_open_outlined,
              message: 'This folder is empty.',
            ),
          );
        } else {
          body = ListView.separated(
            // Always scrollable (not just when content overflows) so the
            // pull-to-refresh gesture below still has room to register on
            // a short list.
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: controller.entries.length,
            separatorBuilder: (context, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = controller.entries[index];
              final canOpenFileLocation =
                  !entry.isDirectory &&
                  defaultTargetPlatform == TargetPlatform.windows &&
                  widget.syncFolder != null &&
                  controller.materializedRelativePath(entry.node.id) != null;
              return ListTile(
                leading: entry.isDirectory
                    ? _folderListIcon
                    : _FileListLeading(entry: entry, controller: controller),
                title: Text(entry.name),
                subtitle: entry.isDirectory
                    ? null
                    : Text(_fileEntrySubtitle(entry)),
                onTap: entry.isDirectory
                    ? () => controller.openFolder(entry)
                    : () => _openOrDownloadFile(context, entry),
                trailing: PopupMenuButton<String>(
                  tooltip: 'More actions',
                  onSelected: (value) => switch (value) {
                    'save_as' => _downloadFile(context, entry),
                    'open_file_location' => _openFileLocation(context, entry),
                    'share' => _shareFile(context, entry),
                    'replace' => _replaceContent(context, entry),
                    'rename' => _renameEntry(context, entry),
                    'delete' => _deleteEntry(context, entry),
                    _ => null,
                  },
                  itemBuilder: (context) => [
                    if (!entry.isDirectory && widget.androidFileSharer != null)
                      PopupMenuItem(
                        value: 'share',
                        child: Text(
                          _localized(context, en: 'Share', ru: 'Поделиться'),
                        ),
                      ),
                    if (!entry.isDirectory)
                      const PopupMenuItem(
                        value: 'save_as',
                        child: Text('Save as…'),
                      ),
                    if (canOpenFileLocation)
                      PopupMenuItem(
                        value: 'open_file_location',
                        child: Text(
                          _localized(
                            context,
                            en: 'Open file location',
                            ru: 'Открыть расположение',
                          ),
                        ),
                      ),
                    if (!entry.isDirectory)
                      const PopupMenuItem(
                        value: 'replace',
                        child: Text('Replace content…'),
                      ),
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Move to trash'),
                    ),
                  ],
                ),
              );
            },
          );
        }
        return _PageFrame(
          title: _localized(context, en: 'Files', ru: 'Файлы'),
          subtitle: controller.breadcrumbNames.isEmpty
              ? _localized(context, en: 'Root', ru: 'Корень')
              : controller.breadcrumbNames.join(' / '),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  PopupMenuButton<FileListSort>(
                    tooltip: 'Sort files',
                    icon: const Icon(Icons.sort),
                    onSelected: controller.setSort,
                    itemBuilder: (context) => FileListSort.values
                        .map(
                          (sort) => CheckedPopupMenuItem<FileListSort>(
                            value: sort,
                            checked: sort == controller.sort,
                            child: Text(_fileSortLabel(sort)),
                          ),
                        )
                        .toList(growable: false),
                  ),
                  if (controller.canGoUp)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: controller.goUp,
                          icon: const Icon(Icons.arrow_upward),
                          tooltip: 'Up one level',
                        ),
                        IconButton(
                          onPressed: controller.goToRoot,
                          icon: const Icon(Icons.home_outlined),
                          tooltip: 'Root',
                        ),
                      ],
                    ),
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    IconButton(
                      onPressed: controller.busy
                          ? null
                          : () => _createFolder(context),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      tooltip: 'New folder',
                    ),
                    if (widget.onCapturePhoto != null)
                      IconButton(
                        onPressed: controller.busy
                            ? null
                            : widget.onCapturePhoto,
                        icon: const Icon(Icons.photo_camera_outlined),
                        tooltip: 'Camera',
                      ),
                    IconButton(
                      onPressed: controller.busy
                          ? null
                          : () => _uploadFiles(context),
                      icon: const Icon(Icons.upload_outlined),
                      tooltip: 'Upload files',
                    ),
                  ] else ...[
                    OutlinedButton.icon(
                      onPressed: controller.busy
                          ? null
                          : () => _createFolder(context),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('New folder'),
                    ),
                    if (widget.onCapturePhoto != null)
                      FilledButton.tonalIcon(
                        onPressed: controller.busy
                            ? null
                            : widget.onCapturePhoto,
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Camera'),
                      ),
                    FilledButton.icon(
                      onPressed: controller.busy
                          ? null
                          : () => _uploadFiles(context),
                      icon: const Icon(Icons.upload_outlined),
                      label: const Text('Upload files'),
                    ),
                  ],
                ],
              ),
              if (defaultTargetPlatform == TargetPlatform.windows) ...[
                const SizedBox(height: 8),
                Text(
                  'Drag files into this window to encrypt and upload them to this folder.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: widget.onPullToRefresh == null
                    ? body
                    : RefreshIndicator(
                        onRefresh: widget.onPullToRefresh!,
                        child: body,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _FilesMessageState extends StatelessWidget {
  const _FilesMessageState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 72),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _SyncSection extends StatelessWidget {
  const _SyncSection({
    required this.syncFolder,
    required this.onSelectSyncFolder,
    required this.onOpenSyncFolder,
    required this.syncEngine,
    required this.syncFolderMaterializer,
    required this.localFolderUploader,
    required this.syncFolderWatcher,
    required this.onToggleSyncPause,
    required this.onResyncVault,
    required this.resyncingVault,
  });
  final String? syncFolder;
  final Future<void> Function() onSelectSyncFolder;
  final Future<void> Function()? onOpenSyncFolder;
  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final LocalFolderUploader? localFolderUploader;
  final SyncFolderWatcher syncFolderWatcher;
  final VoidCallback onToggleSyncPause;
  final Future<void> Function() onResyncVault;
  final bool resyncingVault;

  @override
  Widget build(BuildContext context) {
    final engine = syncEngine;
    return _PageFrame(
      title: _localized(context, en: 'Sync', ru: 'Синхронизация'),
      subtitle: engine == null
          ? _localized(
              context,
              en: 'Sync is paused while the E2EE vault is locked.',
              ru: 'Синхронизация приостановлена, пока E2EE-хранилище заблокировано.',
            )
          : _localized(
              context,
              en: 'The local cache and outbox sync with the server automatically.',
              ru: 'Локальный кэш и очередь автоматически синхронизируются с сервером.',
            ),
      child: ListView(
        children: [
          if (engine == null)
            const Card(
              child: ListTile(
                leading: Icon(Icons.pause_circle_outline),
                title: Text('Sync paused'),
                subtitle: Text(
                  'Provision this device with a trusted device or Recovery Secret.',
                ),
                trailing: Chip(label: Text('Locked')),
              ),
            )
          else
            AnimatedBuilder(
              animation: Listenable.merge([engine, ?syncFolderMaterializer]),
              builder: (context, _) {
                final (
                  icon,
                  label,
                  color,
                  tooltip,
                ) = _effectiveSyncStatusPresentation(
                  engine: engine,
                  materializer: syncFolderMaterializer,
                );
                return Card(
                  child: ListTile(
                    leading: Icon(icon, color: color),
                    title: Text(label),
                    subtitle: tooltip != null
                        ? Text(tooltip)
                        : engine.isPaused
                        ? const Text(
                            'No new sync pass starts until you resume.',
                          )
                        : null,
                    trailing: OutlinedButton.icon(
                      onPressed: onToggleSyncPause,
                      icon: Icon(
                        engine.isPaused
                            ? Icons.play_arrow_outlined
                            : Icons.pause_outlined,
                      ),
                      label: Text(engine.isPaused ? 'Resume' : 'Pause'),
                    ),
                  ),
                );
              },
            ),
          if (defaultTargetPlatform == TargetPlatform.android)
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Local sync folder'),
                subtitle: Text(
                  syncFolder == null
                      ? 'Choose a folder to mirror server files on this device.'
                      : 'Server changes download here automatically. Tap a mirrored file in Files to open it.',
                ),
                isThreeLine: syncFolder != null,
                trailing: TextButton(
                  onPressed: onSelectSyncFolder,
                  child: Text(syncFolder == null ? 'Choose' : 'Change'),
                ),
              ),
            )
          else
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Local sync folder'),
                subtitle: Text(
                  syncFolder == null
                      ? 'Not selected — files stay reachable only through the Files page.'
                      : '$syncFolder\nFilesystem changes are picked up automatically. New local folders and their files are uploaded; directory deletes remain conservative.',
                ),
                isThreeLine: syncFolder != null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (syncFolder != null && onOpenSyncFolder != null)
                      OutlinedButton.icon(
                        onPressed: onOpenSyncFolder,
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('Open'),
                      ),
                    if (syncFolder != null && onOpenSyncFolder != null)
                      const SizedBox(width: 8),
                    TextButton(
                      onPressed: onSelectSyncFolder,
                      child: Text(syncFolder == null ? 'Choose' : 'Change'),
                    ),
                  ],
                ),
              ),
            ),
          if (syncFolder != null && syncFolderMaterializer != null)
            AnimatedBuilder(
              animation: syncFolderMaterializer!,
              builder: (context, _) {
                final materializer = syncFolderMaterializer!;
                final (icon, label) = switch (materializer.status) {
                  SyncFolderStatus.idle => (
                    Icons.check_circle_outline,
                    'Folder mirrors the vault',
                  ),
                  SyncFolderStatus.materializing => (
                    Icons.download_outlined,
                    'Writing files to the folder…',
                  ),
                  SyncFolderStatus.error => (
                    Icons.error_outline,
                    'Could not update the folder',
                  ),
                };
                final progress = materializer.transferProgress;
                final activeFileName = materializer.activeFileName;
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        materializer.status == SyncFolderStatus.error &&
                            materializer.errorMessage != null
                        ? Text(materializer.errorMessage!)
                        : materializer.status ==
                                  SyncFolderStatus.materializing &&
                              progress != null &&
                              activeFileName != null
                        ? _syncFolderTransferProgress(
                            verb: 'Downloading',
                            fileName: activeFileName,
                            progress: progress,
                          )
                        : materializer.status == SyncFolderStatus.materializing
                        ? const Text('Preparing the local folder…')
                        : null,
                  ),
                );
              },
            ),
          if (syncFolder != null &&
              localFolderUploader != null &&
              defaultTargetPlatform != TargetPlatform.android)
            AnimatedBuilder(
              animation: localFolderUploader!,
              builder: (context, _) {
                final uploader = localFolderUploader!;
                final (icon, label) = switch (uploader.status) {
                  LocalUploadStatus.idle => (
                    Icons.check_circle_outline,
                    'No local changes pending',
                  ),
                  LocalUploadStatus.scanning => (
                    Icons.upload_outlined,
                    'Uploading local changes…',
                  ),
                  LocalUploadStatus.resyncing => (
                    Icons.cloud_upload_outlined,
                    'Rebuilding Vault from local folder…',
                  ),
                  LocalUploadStatus.error => (
                    Icons.error_outline,
                    'Could not upload local changes',
                  ),
                };
                final progress = uploader.transferProgress;
                final activeFileName = uploader.activeFileName;
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        uploader.status == LocalUploadStatus.error &&
                            uploader.errorMessage != null
                        ? Text(uploader.errorMessage!)
                        : uploader.status == LocalUploadStatus.scanning &&
                              progress != null &&
                              activeFileName != null
                        ? _syncFolderTransferProgress(
                            verb: 'Uploading',
                            fileName: activeFileName,
                            progress: progress,
                          )
                        : uploader.status == LocalUploadStatus.scanning
                        ? const Text('Scanning local changes…')
                        : uploader.status == LocalUploadStatus.resyncing
                        ? const Text(
                            'Moving the old Vault to Trash and uploading a fresh encrypted tree…',
                          )
                        : null,
                  ),
                );
              },
            ),
          if (syncFolder != null &&
              engine != null &&
              localFolderUploader != null &&
              defaultTargetPlatform != TargetPlatform.android)
            Card(
              child: ListTile(
                leading: const Icon(Icons.restart_alt_outlined),
                title: const Text('Resync from local folder'),
                subtitle: const Text(
                  'Move the current server Vault to Trash, then upload this folder again from scratch.',
                ),
                trailing: FilledButton.icon(
                  key: const ValueKey('resync-vault'),
                  onPressed: resyncingVault ? null : onResyncVault,
                  icon: resyncingVault
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restart_alt_outlined),
                  label: Text(resyncingVault ? 'Resyncing…' : 'Resync'),
                ),
              ),
            ),
          if (syncFolder != null &&
              defaultTargetPlatform != TargetPlatform.android)
            AnimatedBuilder(
              animation: syncFolderWatcher,
              builder: (context, _) {
                final (icon, label) = switch (syncFolderWatcher.status) {
                  SyncFolderWatcherStatus.stopped => (
                    Icons.pause_circle_outline,
                    'Folder watcher stopped',
                  ),
                  SyncFolderWatcherStatus.watching => (
                    Icons.visibility_outlined,
                    'Watching local changes',
                  ),
                  SyncFolderWatcherStatus.error => (
                    Icons.error_outline,
                    'Folder watcher needs attention',
                  ),
                };
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        syncFolderWatcher.status ==
                                SyncFolderWatcherStatus.error &&
                            syncFolderWatcher.errorMessage != null
                        ? Text(syncFolderWatcher.errorMessage!)
                        : const Text(
                            'Changes are debounced before a safe sync pass.',
                          ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Shared inline progress display for both directions of local-folder sync.
/// File transfers report byte/chunk progress; scanning and folder creation
/// remain intentionally indeterminate until a concrete file starts moving.
Widget _syncFolderTransferProgress({
  required String verb,
  required String fileName,
  required double progress,
}) {
  final percent = (progress * 100).round().clamp(0, 100);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$verb $fileName — $percent%'),
      const SizedBox(height: 6),
      LinearProgressIndicator(value: progress),
    ],
  );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.deviceSetupController,
    required this.deviceProvisioningController,
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.onVaultProvisioned,
    required this.localeController,
  });

  final DeviceSetupController deviceSetupController;
  final DeviceProvisioningController deviceProvisioningController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final Future<void> Function() onVaultProvisioned;
  final AppLocaleController localeController;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: _localized(context, en: 'Settings', ru: 'Настройки'),
    subtitle: _localized(
      context,
      en: 'Connection and device security.',
      ru: 'Подключение и безопасность устройства.',
    ),
    child: ListView(
      children: [
        _LanguageCard(controller: localeController),
        _ServerConnectionCard(controller: serverConnectionController),
        _DeviceIdentityCard(controller: deviceSetupController),
        _DeviceProvisioningCard(
          controller: deviceProvisioningController,
          deviceSetupController: deviceSetupController,
          serverConnectionController: serverConnectionController,
          vaultSetupController: vaultSetupController,
          onVaultProvisioned: onVaultProvisioned,
        ),
        _AccountDevicesCard(
          controller: deviceProvisioningController,
          serverConnectionController: serverConnectionController,
          vaultSetupController: vaultSetupController,
        ),
        _VaultSetupCard(
          controller: vaultSetupController,
          serverConnectionController: serverConnectionController,
          deviceProvisioningController: deviceProvisioningController,
        ),
        const _AutostartCard(),
      ],
    ),
  );
}

final class _LanguageCard extends StatelessWidget {
  const _LanguageCard({required this.controller});

  final AppLocaleController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.language_outlined),
          title: Text(_localized(context, en: 'Language', ru: 'Язык')),
          subtitle: Text(
            _localized(
              context,
              en: 'Choose the application interface language.',
              ru: 'Выберите язык интерфейса приложения.',
            ),
          ),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<AppLanguage>(
              value: controller.language,
              onChanged: (language) {
                if (language != null) {
                  unawaited(controller.setLanguage(language));
                }
              },
              items: const [
                DropdownMenuItem(
                  value: AppLanguage.english,
                  child: Text('English'),
                ),
                DropdownMenuItem(
                  value: AppLanguage.russian,
                  child: Text('Русский'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

final class _DeviceProvisioningCard extends StatelessWidget {
  const _DeviceProvisioningCard({
    required this.controller,
    required this.deviceSetupController,
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.onVaultProvisioned,
  });

  final DeviceProvisioningController controller;
  final DeviceSetupController deviceSetupController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final Future<void> Function() onVaultProvisioned;

  Future<void> _addDevice(BuildContext context) async {
    final devices = await controller.availableRecipientDevices();
    if (!context.mounted) return;
    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ?? 'No other active device is registered yet. Sign in on the new device first.',
          ),
        ),
      );
      return;
    }
    final target = await showDialog<transport.HomeBoxDevice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose a device to approve'),
        content: SizedBox(
          width: 420,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: devices.length,
            separatorBuilder: (context, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final device = devices[index];
              return ListTile(
                leading: Icon(
                  device.platform == 'ANDROID'
                      ? Icons.phone_android_outlined
                      : Icons.desktop_windows_outlined,
                ),
                title: Text('${device.name} (${_deviceCode(device.id)})'),
                subtitle: Text(
                  '${device.platform} · Last seen ${device.lastSeenAt.toLocal()}',
                ),
                onTap: () => Navigator.pop(context, device),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!context.mounted || target == null) return;
    final targetFingerprint = await devicePublicKeyFingerprint(
      target.publicKey,
    );
    if (!context.mounted) return;
    var fingerprintVerified = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Verify and approve device'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'On ${target.name}, open Settings → This device. Compare the full pairing fingerprint before sharing the vault key.',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  targetFingerprint,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: fingerprintVerified,
                  onChanged: (value) => setDialogState(
                    () => fingerprintVerified = value ?? false,
                  ),
                  title: const Text(
                    'The fingerprint exactly matches the new device',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: fingerprintVerified
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Sign and approve'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final approved = await controller.provisionDevice(
      target,
      fingerprintVerified: fingerprintVerified,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          approved
              ? 'Device approved. Open Settings there and choose Check approval.'
              : (controller.errorMessage ?? 'Could not approve this device.'),
        ),
      ),
    );
  }

  Future<void> _checkApproval(BuildContext context) async {
    final provisioned = await controller.collectProvisioning();
    if (provisioned) await onVaultProvisioned();
    if (!context.mounted) return;
    final message = provisioned
        ? 'This device is approved and the vault is unlocked.'
        : controller.status == DeviceProvisioningStatus.awaitingApproval
        ? 'Waiting for approval from a trusted device.'
        : (controller.errorMessage ?? 'Could not check device approval.');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller,
      deviceSetupController,
      serverConnectionController,
      vaultSetupController,
    ]),
    builder: (context, _) {
      final signedIn =
          serverConnectionController.status ==
          ServerConnectionStatus.authenticated;
      final vaultReady = vaultSetupController.status == VaultSetupStatus.ready;
      final deviceReady =
          deviceSetupController.status == DeviceSetupStatus.ready;
      final canApproveAnother = signedIn && vaultReady;
      final canCollectApproval = signedIn && !vaultReady && deviceReady;
      final deviceCode = signedIn
          ? _deviceCode(serverConnectionController.session!.device.id)
          : null;
      final subtitle = switch (controller.status) {
        DeviceProvisioningStatus.loading =>
          'Exchanging the encrypted vault key…',
        DeviceProvisioningStatus.awaitingApproval =>
          'Waiting for a trusted device to approve this device.',
        DeviceProvisioningStatus.ready =>
          vaultReady
              ? 'This device can approve another signed-in device.'
              : 'Vault key received from a trusted device.',
        DeviceProvisioningStatus.failed =>
          controller.errorMessage ?? 'Provisioning failed.',
        DeviceProvisioningStatus.idle when !signedIn =>
          'Sign in on both devices before linking them.',
        DeviceProvisioningStatus.idle when !deviceReady =>
          'Prepare this device identity before linking it.',
        DeviceProvisioningStatus.idle when vaultReady =>
          'Approve another device that has signed in to this account.',
        DeviceProvisioningStatus.idle => 'Sign in on a trusted device, approve this one there, then check here.',
      };
      final trailing = controller.busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : canApproveAnother
          ? OutlinedButton(
              onPressed: () => _addDevice(context),
              child: const Text('Add device'),
            )
          : canCollectApproval
          ? FilledButton(
              onPressed: () => _checkApproval(context),
              child: const Text('Check approval'),
            )
          : null;
      return Card(
        child: ListTile(
          leading: const Icon(Icons.phonelink_lock_outlined),
          title: const Text('Trusted devices'),
          subtitle: Text(
            deviceCode == null
                ? subtitle
                : '$subtitle\nDevice code: $deviceCode',
          ),
          trailing: trailing,
          isThreeLine: true,
        ),
      );
    },
  );
}

String _deviceCode(String deviceId) => deviceId.substring(0, 8).toUpperCase();

final class _AccountDevicesCard extends StatefulWidget {
  const _AccountDevicesCard({
    required this.controller,
    required this.serverConnectionController,
    required this.vaultSetupController,
  });

  final DeviceProvisioningController controller;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;

  @override
  State<_AccountDevicesCard> createState() => _AccountDevicesCardState();
}

final class _AccountDevicesCardState extends State<_AccountDevicesCard> {
  List<transport.HomeBoxDevice> _devices = const [];
  bool _loading = false;
  bool _revoking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.serverConnectionController.addListener(_onConnectionChanged);
    _onConnectionChanged();
  }

  @override
  void dispose() {
    widget.serverConnectionController.removeListener(_onConnectionChanged);
    super.dispose();
  }

  void _onConnectionChanged() {
    if (widget.serverConnectionController.status ==
        ServerConnectionStatus.authenticated) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    var devices = await widget.controller.accountDevices();
    if (await _selfHealOwnApproval(devices)) {
      devices = await widget.controller.accountDevices();
    }
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _error = widget.controller.errorMessage;
      _loading = false;
    });
  }

  /// A vault's creator device never goes through the normal approve/collect
  /// flow (there is no other trusted device yet to approve it), so it can
  /// show up here as pending even though it already holds the vault key
  /// locally — including vaults created before this self-approval step
  /// existed. Silently repairs that the first time this device's own vault
  /// is ready but the server has no record of it, retrying on every load
  /// until it succeeds.
  Future<bool> _selfHealOwnApproval(
    List<transport.HomeBoxDevice> devices,
  ) async {
    final selfId = widget.serverConnectionController.session?.device.id;
    if (selfId == null ||
        widget.vaultSetupController.status != VaultSetupStatus.ready) {
      return false;
    }
    transport.HomeBoxDevice? self;
    for (final device in devices) {
      if (device.id == selfId) {
        self = device;
        break;
      }
    }
    if (self == null || self.hasVaultKey) return false;
    return widget.controller.selfApprove();
  }

  Future<void> _revoke(transport.HomeBoxDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke this device?'),
        content: Text(
          '${device.name} (${_deviceCode(device.id)}) will be signed out '
          'immediately and must be approved again by a trusted device before '
          'it can access the vault. This cannot retract a vault key it has '
          'already received.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revoking = true);
    final revoked = await widget.controller.revokeDevice(device);
    if (!mounted) return;
    setState(() => _revoking = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          revoked
              ? '${device.name} has been revoked.'
              : (widget.controller.errorMessage ??
                    'Could not revoke this device.'),
        ),
      ),
    );
    if (revoked) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn =
        widget.serverConnectionController.status ==
        ServerConnectionStatus.authenticated;
    final currentDeviceId = signedIn
        ? widget.serverConnectionController.session?.device.id
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.devices_other_outlined),
              title: const Text('Account devices'),
              subtitle: const Text(
                'Approved devices hold the vault key; pending devices are '
                'signed in but still waiting for approval.',
              ),
              trailing: IconButton(
                tooltip: 'Refresh devices',
                onPressed: !signedIn || _loading ? null : _load,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_outlined),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else if (signedIn && !_loading && _devices.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No other device is signed in yet.'),
                ),
              )
            else
              for (final device in _devices)
                ListTile(
                  dense: true,
                  leading: Icon(
                    device.platform == 'ANDROID'
                        ? Icons.phone_android_outlined
                        : Icons.desktop_windows_outlined,
                    color: device.hasVaultKey
                        ? Colors.green
                        : Theme.of(context).colorScheme.outline,
                  ),
                  title: Text(
                    '${device.name} (${_deviceCode(device.id)})'
                    '${device.id == currentDeviceId ? ' · this device' : ''}',
                  ),
                  subtitle: Row(
                    children: [
                      Icon(
                        device.hasVaultKey
                            ? Icons.check_circle_outline
                            : Icons.hourglass_empty_outlined,
                        size: 14,
                        color: device.hasVaultKey
                            ? Colors.green
                            : Colors.orange,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          device.hasVaultKey
                              ? (device.lastSyncAt != null
                                    ? 'Approved · Last sync: ${_formatLocalDateTime(device.lastSyncAt!)}'
                                    : 'Approved')
                              : 'Pending approval',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  trailing: device.id == currentDeviceId
                      ? null
                      : IconButton(
                          tooltip: 'Revoke device',
                          onPressed: _revoking ? null : () => _revoke(device),
                          icon: const Icon(Icons.block_outlined),
                        ),
                ),
          ],
        ),
      ),
    );
  }
}

String _formatLocalDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

final class _AutostartCard extends StatefulWidget {
  const _AutostartCard();

  @override
  State<_AutostartCard> createState() => _AutostartCardState();
}

final class _AutostartCardState extends State<_AutostartCard> {
  final WindowsAutostart _autostart = WindowsAutostart();
  bool? _enabled;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _autostart.enabled();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  Future<void> _set(bool value) async {
    setState(() => _loading = true);
    final enabled = await _autostart.setEnabled(value);
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: SwitchListTile(
      secondary: const Icon(Icons.rocket_launch_outlined),
      title: const Text('Start HomeBox with Windows'),
      subtitle: Text(
        _enabled == null
            ? 'Available in the Windows desktop build.'
            : 'Uses your current Windows account only.',
      ),
      value: _enabled ?? false,
      onChanged: _loading || _enabled == null ? null : _set,
    ),
  );
}

final class _DeviceIdentityCard extends StatelessWidget {
  const _DeviceIdentityCard({required this.controller});

  final DeviceSetupController controller;

  Future<void> _confirmPreparation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Prepare this device?'),
        content: const Text(
          'HomeBox will create an X25519 private key protected by secure storage on this device. '
          'This does not unlock the vault until a trusted device or Recovery Secret approves it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create identity'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.prepareDevice();
  }

  Future<void> _copyFingerprint(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Device fingerprint copied.')));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final fingerprint = controller.publicKeyFingerprint;
      final subtitle = switch (controller.status) {
        DeviceSetupStatus.checking => 'Checking secure storage…',
        DeviceSetupStatus.missing =>
          'No device identity. Create one before requesting provisioning.',
        DeviceSetupStatus.creating =>
          'Creating a device-bound X25519 identity…',
        DeviceSetupStatus.ready =>
          'Identity ready · Not provisioned\nFingerprint: $fingerprint',
        DeviceSetupStatus.failed =>
          'Secure storage is unavailable or contains invalid data.',
      };
      final trailing = switch (controller.status) {
        DeviceSetupStatus.checking ||
        DeviceSetupStatus.creating => const SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        DeviceSetupStatus.missing => FilledButton(
          key: const ValueKey('prepare-device'),
          onPressed: () => _confirmPreparation(context),
          child: const Text('Prepare device'),
        ),
        DeviceSetupStatus.ready => IconButton(
          tooltip: 'Copy public-key fingerprint',
          onPressed: fingerprint == null
              ? null
              : () => _copyFingerprint(context, fingerprint),
          icon: const Icon(Icons.copy_outlined),
        ),
        DeviceSetupStatus.failed => TextButton(
          onPressed: controller.initialize,
          child: const Text('Retry'),
        ),
      };
      return Card(
        child: ListTile(
          leading: const Icon(Icons.devices_other_outlined),
          title: const Text('This device'),
          subtitle: Text(subtitle),
          trailing: trailing,
          isThreeLine: controller.status == DeviceSetupStatus.ready,
        ),
      );
    },
  );
}

final class _ServerConnectionCard extends StatelessWidget {
  const _ServerConnectionCard({required this.controller});

  final ServerConnectionController controller;

  Future<void> _promptForServer(BuildContext context) async {
    final urlController = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to a HomeBox server'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'homebox.local:8787',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, urlController.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (entered == null || entered.trim().isEmpty) return;
    await controller.discover(entered);
  }

  Future<void> _confirmFingerprint(
    BuildContext context,
    String fingerprint,
  ) async {
    final trust = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify server identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Compare this fingerprint with the one printed by "homebox server fingerprint" '
              'on the server, over a channel you trust, before continuing.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              fingerprint,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Trust this server'),
          ),
        ],
      ),
    );
    if (trust == true) {
      await controller.confirmTrust();
    } else {
      controller.cancelTrust();
    }
  }

  Future<void> _promptForLogin(BuildContext context) async {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (submitted == true) {
      await controller.login(usernameController.text, passwordController.text);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final cards = <Widget>[
        Card(
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(controller.server?.baseUrl ?? 'Not connected'),
            trailing: switch (controller.status) {
              ServerConnectionStatus.discovering ||
              ServerConnectionStatus.authenticating => const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              ServerConnectionStatus.disconnected ||
              ServerConnectionStatus.failed => FilledButton(
                onPressed: () => _promptForServer(context),
                child: const Text('Connect'),
              ),
              _ => TextButton(
                onPressed: () => controller.forgetServer(),
                child: const Text('Forget'),
              ),
            },
          ),
        ),
      ];

      if (controller.status == ServerConnectionStatus.failed &&
          controller.errorMessage != null) {
        cards.add(
          Card(
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('Connection failed'),
              subtitle: Text(controller.errorMessage!),
            ),
          ),
        );
      }

      if (controller.status == ServerConnectionStatus.awaitingTrust &&
          controller.discoveredFingerprint != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            _confirmFingerprint(context, controller.discoveredFingerprint!);
          }
        });
      }

      if (controller.status == ServerConnectionStatus.connectedLoggedOut ||
          controller.status == ServerConnectionStatus.authenticated) {
        final session = controller.session;
        cards.add(
          Card(
            child: ListTile(
              leading: Icon(
                session != null
                    ? Icons.verified_user_outlined
                    : Icons.person_outline,
              ),
              title: Text(
                session != null
                    ? 'Signed in as ${session.user.username}'
                    : 'Not signed in',
              ),
              subtitle: session == null && controller.errorMessage != null
                  ? Text(controller.errorMessage!)
                  : null,
              trailing: session != null
                  ? TextButton(
                      onPressed: () => controller.logout(),
                      child: const Text('Sign out'),
                    )
                  : FilledButton(
                      onPressed: () => _promptForLogin(context),
                      child: const Text('Sign in'),
                    ),
            ),
          ),
        );
      }

      return Column(children: cards);
    },
  );
}

final class _VaultSetupCard extends StatelessWidget {
  const _VaultSetupCard({
    required this.controller,
    required this.serverConnectionController,
    required this.deviceProvisioningController,
  });

  final VaultSetupController controller;
  final ServerConnectionController serverConnectionController;
  final DeviceProvisioningController deviceProvisioningController;

  Future<void> _createVault(BuildContext context) async {
    final userId = serverConnectionController.session?.user.id;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in to the server before creating a vault.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create this account\'s vault?'),
        content: const Text(
          'HomeBox generates the encryption keys that protect your files on this server, plus a Recovery Secret you must save. '
          'If every trusted device and the Recovery Secret are lost, nobody — including HomeBox — can recover your files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create vault'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final secret = await controller.createVault(userId);
    if (secret == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              controller.errorMessage ?? 'Could not create the vault.',
            ),
          ),
        );
      }
      return;
    }
    // This device is the vault's root of trust and never goes through
    // collectProvisioning, so without this it would show as still pending
    // approval in Account devices. Best-effort: the vault itself already
    // exists and its Recovery Secret must still be shown either way.
    final selfApproved = await deviceProvisioningController.selfApprove();
    if (!context.mounted) return;
    await _showRecoverySecret(context, secret);
    if (!selfApproved && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Vault created, but this device could not record its own approval: '
            '${deviceProvisioningController.errorMessage ?? 'unknown error'}. '
            'It may show as pending in Account devices until this is retried.',
          ),
        ),
      );
    }
  }

  Future<void> _showRecoverySecret(BuildContext context, String secret) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          var confirmedSaved = false;
          // A single StatefulBuilder wraps the whole dialog so toggling the
          // checkbox also rebuilds the "Done" button's enabled state — two
          // separate StatefulBuilders (one per widget) would each keep their
          // own rebuild scope and never see the other's state change.
          return StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: const Text('Save your Recovery Secret'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This is shown only once. Without it — and without another trusted device — your files can never be recovered.',
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    secret,
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: confirmedSaved,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) =>
                        setState(() => confirmedSaved = value ?? false),
                    title: const Text(
                      'I have saved this Recovery Secret somewhere safe.',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: secret)),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy'),
                ),
                FilledButton(
                  onPressed: confirmedSaved
                      ? () => Navigator.pop(context)
                      : null,
                  child: const Text('Done'),
                ),
              ],
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final subtitle = switch (controller.status) {
        VaultSetupStatus.checking => 'Checking for an existing vault…',
        VaultSetupStatus.locked => 'No vault on this device yet. Create one here, or unlock this device from an existing trusted device / Recovery Secret.',
        VaultSetupStatus.creating => 'Creating vault keys…',
        VaultSetupStatus.ready => 'Vault ready on this device.',
        VaultSetupStatus.failed =>
          controller.errorMessage ?? 'Vault storage is unavailable.',
      };
      final trailing = switch (controller.status) {
        VaultSetupStatus.checking ||
        VaultSetupStatus.creating => const SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        VaultSetupStatus.locked => FilledButton(
          onPressed: () => _createVault(context),
          child: const Text('Create vault'),
        ),
        VaultSetupStatus.ready => const Icon(Icons.check_circle_outline),
        VaultSetupStatus.failed => TextButton(
          onPressed: controller.initialize,
          child: const Text('Retry'),
        ),
      };
      return Card(
        child: ListTile(
          leading: const Icon(Icons.enhanced_encryption_outlined),
          title: const Text('Personal vault'),
          subtitle: Text(subtitle),
          trailing: trailing,
          isThreeLine: true,
        ),
      );
    },
  );
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 24),
        Expanded(child: child),
      ],
    ),
  );
}
