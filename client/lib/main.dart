import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'core/e2ee/account_identity.dart';
import 'core/e2ee/device_identity.dart';
import 'core/e2ee/vault_key_store.dart';
import 'core/localization/app_locale_controller.dart';
import 'core/localization/app_theme_controller.dart';
import 'core/platform/android_file_saver.dart';
import 'core/platform/android_file_sharer.dart';
import 'core/platform/android_sync_folder.dart';
import 'core/platform/biometric_authenticator.dart';
import 'core/platform/camera_photo_picker.dart';
import 'core/platform/windows_autostart.dart';
import 'core/platform/windows_file_drop.dart';
import 'core/platform/windows_sync_folder.dart';
import 'core/storage/local_database.dart';
import 'core/storage/sync_conflicts_store.dart';
import 'core/util/local_path.dart';
import 'features/device/device_setup_controller.dart';
import 'features/device/device_provisioning_controller.dart';
import 'features/files/download_notification_controller.dart';
import 'features/files/files_controller.dart';
import 'features/files/image_thumbnail.dart';
import 'features/files/unique_name.dart';
import 'features/server/server_connection_controller.dart';
import 'features/sharing/family_vault_controller.dart';
import 'features/sharing/shared_folder_browser.dart';
import 'features/sync/outbox_conflict_resolver.dart';
import 'features/sync/sync_conflict_log.dart';
import 'features/sync/sync_engine.dart';
import 'features/syncfolder/local_folder_uploader.dart';
import 'features/syncfolder/sync_folder_materializer.dart';
import 'features/syncfolder/sync_folder_store.dart';
import 'features/syncfolder/sync_folder_watcher.dart';
import 'features/vault/recovery_controller.dart';
import 'features/vault/vault_setup_controller.dart';
import 'core/transport/homebox_api_client.dart' as transport;

part 'ui/bulk_actions.dart';
part 'ui/family_section.dart';
part 'ui/file_history.dart';
part 'ui/files_section.dart';
part 'ui/settings_section.dart';
part 'ui/shell_widgets.dart';
part 'ui/sync_section.dart';

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
    this.themeController,
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
  final AppThemeController? themeController;

  @override
  State<HomeBoxApp> createState() => _HomeBoxAppState();
}

const Color _brandSeedColor = Color(0xff176b87);

class _HomeBoxAppState extends State<HomeBoxApp> {
  late final AppLocaleController _localeController;
  late final bool _ownsLocaleController;
  late final AppThemeController _themeController;
  late final bool _ownsThemeController;

  @override
  void initState() {
    super.initState();
    _ownsLocaleController = widget.localeController == null;
    _localeController = widget.localeController ?? AppLocaleController();
    if (_ownsLocaleController) unawaited(_localeController.initialize());
    _ownsThemeController = widget.themeController == null;
    _themeController = widget.themeController ?? AppThemeController();
    if (_ownsThemeController) unawaited(_themeController.initialize());
  }

  @override
  void dispose() {
    if (_ownsLocaleController) _localeController.dispose();
    if (_ownsThemeController) _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_localeController, _themeController]),
    builder: (context, _) => MaterialApp(
      title: 'HomeBox',
      locale: Locale(_localeController.language.languageCode),
      supportedLocales: const [Locale('en'), Locale('ru')],
      // Built-in widget strings (tooltips such as "Back", text-selection
      // menus, dialogs' barrier labels) follow the chosen language too.
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: _themeController.mode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _brandSeedColor),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandSeedColor,
          brightness: Brightness.dark,
        ),
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
        themeController: _themeController,
      ),
    ),
  );
}

enum AppSection { files, family, sync, settings }

String _localized(
  BuildContext context, {
  required String en,
  required String ru,
}) => Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

/// Picks the Russian plural form for [n]: 1 файл, 2 файла, 5 файлов.
String _pluralRu(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

/// "[n] items" in the current language with the right plural form.
String _countOf(
  BuildContext context,
  int n, {
  required String enOne,
  required String enMany,
  required String ruOne,
  required String ruFew,
  required String ruMany,
}) => _localized(
  context,
  en: '$n ${n == 1 ? enOne : enMany}',
  ru: '$n ${_pluralRu(n, ruOne, ruFew, ruMany)}',
);

String _itemCount(BuildContext context, int n) => _countOf(
  context,
  n,
  enOne: 'item',
  enMany: 'items',
  ruOne: 'элемент',
  ruFew: 'элемента',
  ruMany: 'элементов',
);

/// "5 minutes ago" / "5 минут назад", measured against [referenceNow].
String _formatRelativeTime(
  BuildContext context,
  DateTime utc,
  DateTime referenceNow,
) {
  final elapsed = referenceNow.toUtc().difference(utc.toUtc());
  final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  String ago(
    int n,
    String enUnit,
    (String one, String few, String many) ruUnit,
  ) => _localized(
    context,
    en: '$n $enUnit${n == 1 ? '' : 's'} ago',
    ru: '$n ${_pluralRu(n, ruUnit.$1, ruUnit.$2, ruUnit.$3)} назад',
  );
  if (seconds < 10) {
    return _localized(context, en: 'just now', ru: 'только что');
  }
  if (seconds < 60) {
    return ago(seconds, 'second', ('секунду', 'секунды', 'секунд'));
  }
  final minutes = seconds ~/ 60;
  if (minutes < 60) {
    return ago(minutes, 'minute', ('минуту', 'минуты', 'минут'));
  }
  final hours = minutes ~/ 60;
  if (hours < 24) return ago(hours, 'hour', ('час', 'часа', 'часов'));
  final days = hours ~/ 24;
  if (days < 30) return ago(days, 'day', ('день', 'дня', 'дней'));
  final months = days ~/ 30;
  if (months < 12) return ago(months, 'month', ('месяц', 'месяца', 'месяцев'));
  return ago(days ~/ 365, 'year', ('год', 'года', 'лет'));
}

/// A success/"all good" accent that keeps enough contrast in both themes;
/// Material 3 has no success role of its own.
Color _successColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Colors.green.shade300
    : Colors.green.shade700;

/// A warning/"needs attention" accent readable in both themes.
Color _warningColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Colors.orange.shade300
    : Colors.orange.shade800;

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
    this.themeController,
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
  final AppThemeController? themeController;

  @override
  State<HomeBoxDesktopPage> createState() => _HomeBoxDesktopPageState();
}

class _HomeBoxDesktopPageState extends State<HomeBoxDesktopPage>
    with WidgetsBindingObserver {
  late final DeviceIdentityStore _deviceIdentityStore;
  late final DeviceSetupController _deviceSetupController;
  late final DeviceProvisioningController _deviceProvisioningController;
  late final ServerConnectionController _serverConnectionController;
  late final VaultKeyStore _vaultKeyStore;
  late final VaultSetupController _vaultSetupController;
  late final RecoveryController _recoveryController;
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
  late final AppThemeController _themeController;
  late final bool _ownsThemeController;
  BiometricAuthenticator? _biometricAuthenticator;
  SyncEngine? _syncEngine;
  FilesController? _filesController;
  FamilyVaultController? _familyVaultController;
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
    WidgetsBinding.instance.addObserver(this);
    _deviceIdentityStore =
        widget.deviceIdentityStore ?? DeviceIdentityStore.platform();
    _deviceSetupController = DeviceSetupController(_deviceIdentityStore);
    _serverConnectionController =
        widget.serverConnectionController ??
        ServerConnectionController(deviceIdentityStore: _deviceIdentityStore);
    _vaultKeyStore = widget.vaultKeyStore ?? VaultKeyStore();
    _vaultSetupController = VaultSetupController(_vaultKeyStore);
    _recoveryController = RecoveryController(
      vaultKeyStore: _vaultKeyStore,
      serverConnection: _serverConnectionController,
    );
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
    _ownsThemeController = widget.themeController == null;
    _themeController = widget.themeController ?? AppThemeController();
    if (_ownsThemeController) unawaited(_themeController.initialize());
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
      final oldFamilyVault = _familyVaultController;
      final oldEngine = _syncEngine;
      final oldMaterializer = _syncFolderMaterializer;
      final oldUploader = _localFolderUploader;
      if (mounted) {
        setState(() {
          _filesController = null;
          _familyVaultController = null;
          _syncEngine = null;
          _syncFolderMaterializer = null;
          _localFolderUploader = null;
        });
      } else {
        _filesController = null;
        _familyVaultController = null;
        _syncEngine = null;
        _syncFolderMaterializer = null;
        _localFolderUploader = null;
      }
      oldFiles?.dispose();
      oldFamilyVault?.dispose();
      oldMaterializer?.dispose();
      oldUploader?.dispose();
      oldEngine?.dispose(); // also closes its LocalDatabase.
      _syncEngineFingerprint = fingerprint;
      if (fingerprint != null) {
        final localDatabase = await LocalDatabase.open(fingerprint);
        late final SyncEngine engine;
        engine = SyncEngine(
          serverConnection: _serverConnectionController,
          localDatabase: localDatabase,
          conflictResolver: VaultOutboxConflictResolver(
            _vaultKeyStore,
            folderKeys: () => engine.folderKeys.all(),
          ),
        );
        final familyVault = FamilyVaultController(
          serverConnection: _serverConnectionController,
          vaultKeyStore: _vaultKeyStore,
          deviceIdentityStore: _deviceIdentityStore,
          syncEngine: engine,
        );
        final files = FilesController(
          serverConnection: _serverConnectionController,
          vaultKeyStore: _vaultKeyStore,
          syncEngine: engine,
          thumbnailer: shrinkImageForThumbnail,
          // Android's folder is a Storage Access Framework tree URI, not a
          // filesystem path, so only Windows can read mirrored copies.
          localSyncFolderRoot: defaultTargetPlatform == TargetPlatform.windows
              ? () => _syncFolder
              : null,
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
          androidSyncFolder: _androidSyncFolder,
        );
        if (!mounted) {
          files.dispose();
          familyVault.dispose();
          materializer.dispose();
          uploader.dispose();
          engine.dispose();
          return;
        }
        setState(() {
          _syncEngine = engine;
          _filesController = files;
          _familyVaultController = familyVault;
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
  /// Android always publishes edits to its mirrored files first, for the same
  /// reason: the pull would otherwise replace an edit whose node changed.
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
    final android = defaultTargetPlatform == TargetPlatform.android;
    try {
      // SAF has no recursive change notifications, so Android polls instead:
      // every pass (each SyncEngine cycle and each return to the foreground)
      // checks the mirrored files for edits made by other apps.
      if (android) await uploader.scanAndroidEdits(folder);
      if (localChange && !android) await uploader.scan(folder);
      await materializer.materialize(folder);
      if (!localChange && !android) await uploader.scan(folder);
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

  /// An edit is usually made by opening a mirrored file in another app, so
  /// returning to HomeBox publishes it at once instead of on the next cycle.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_runSyncFolderPass());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serverConnectionController.removeListener(_onServerConnectionChanged);
    _vaultSetupController.removeListener(_maybeRefreshFiles);
    _filesController?.dispose();
    _familyVaultController?.dispose();
    _syncFolderMaterializer?.dispose();
    _localFolderUploader?.dispose();
    _downloadNotifications.dispose();
    _syncFolderWatcher.dispose();
    _syncEngine?.dispose();
    _vaultSetupController.dispose();
    _recoveryController.dispose();
    _deviceProvisioningController.dispose();
    _deviceSetupController.dispose();
    _serverConnectionController.dispose();
    if (_ownsLocaleController) _localeController.dispose();
    if (_ownsThemeController) _themeController.dispose();
    super.dispose();
  }

  void _showSection(AppSection section) {
    if (_section != section) setState(() => _section = section);
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
        onTap: () => _showSection(AppSection.sync),
      ),
      _VaultStateChip(
        controller: _vaultSetupController,
        onTap: () => _showSection(AppSection.settings),
      ),
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
      recoveryController: _recoveryController,
      onVaultProvisioned: _onVaultProvisioned,
      filesController: _filesController,
      familyVaultController: _familyVaultController,
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
      themeController: _themeController,
      onPullToRefresh: defaultTargetPlatform == TargetPlatform.android
          ? _refreshFromServer
          : null,
      onRefresh: _refreshFromServer,
      onOpenSettings: () => _showSection(AppSection.settings),
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
                _showSection(AppSection.values[index]),
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: _localized(context, en: 'Files', ru: 'Файлы'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.family_restroom_outlined),
                selectedIcon: const Icon(Icons.family_restroom),
                label: _localized(context, en: 'Family', ru: 'Семья'),
              ),
              NavigationDestination(
                icon: _SyncNavigationIcon(
                  conflicts: _syncEngine?.conflicts,
                  icon: Icons.sync_outlined,
                ),
                selectedIcon: _SyncNavigationIcon(
                  conflicts: _syncEngine?.conflicts,
                  icon: Icons.sync,
                ),
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
                    _showSection(AppSection.values[index]),
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
                    icon: const Icon(Icons.family_restroom_outlined),
                    selectedIcon: const Icon(Icons.family_restroom),
                    label: Text(_localized(context, en: 'Family', ru: 'Семья')),
                  ),
                  NavigationRailDestination(
                    icon: _SyncNavigationIcon(
                      conflicts: _syncEngine?.conflicts,
                      icon: Icons.sync_outlined,
                    ),
                    selectedIcon: _SyncNavigationIcon(
                      conflicts: _syncEngine?.conflicts,
                      icon: Icons.sync,
                    ),
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
