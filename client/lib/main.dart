import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/e2ee/device_identity.dart';
import 'core/e2ee/vault_key_store.dart';
import 'core/platform/camera_photo_picker.dart';
import 'core/platform/windows_autostart.dart';
import 'core/platform/windows_file_drop.dart';
import 'core/storage/local_database.dart';
import 'features/device/device_setup_controller.dart';
import 'features/device/device_provisioning_controller.dart';
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

class HomeBoxApp extends StatelessWidget {
  const HomeBoxApp({
    super.key,
    this.deviceIdentityStore,
    this.serverConnectionController,
    this.vaultKeyStore,
    this.syncFolderStore,
    this.cameraPhotoPicker,
  });

  final DeviceIdentityStore? deviceIdentityStore;
  final ServerConnectionController? serverConnectionController;
  final VaultKeyStore? vaultKeyStore;
  final SyncFolderStore? syncFolderStore;
  final CameraPhotoPicker? cameraPhotoPicker;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HomeBox',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b87)),
      useMaterial3: true,
    ),
    home: HomeBoxDesktopPage(
      deviceIdentityStore: deviceIdentityStore,
      serverConnectionController: serverConnectionController,
      vaultKeyStore: vaultKeyStore,
      syncFolderStore: syncFolderStore,
      cameraPhotoPicker: cameraPhotoPicker,
    ),
  );
}

enum AppSection { files, sync, settings }

class HomeBoxDesktopPage extends StatefulWidget {
  const HomeBoxDesktopPage({
    super.key,
    this.deviceIdentityStore,
    this.serverConnectionController,
    this.vaultKeyStore,
    this.syncFolderStore,
    this.cameraPhotoPicker,
  });

  final DeviceIdentityStore? deviceIdentityStore;

  // Overridable purely so tests can supply in-memory-backed instances
  // instead of ones backed by real OS secure storage (see widget_test.dart)
  // — matching the same reason deviceIdentityStore above is overridable.
  final ServerConnectionController? serverConnectionController;
  final VaultKeyStore? vaultKeyStore;
  final SyncFolderStore? syncFolderStore;
  final CameraPhotoPicker? cameraPhotoPicker;

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
  SyncEngine? _syncEngine;
  FilesController? _filesController;
  SyncFolderMaterializer? _syncFolderMaterializer;
  LocalFolderUploader? _localFolderUploader;
  String? _syncEngineFingerprint;
  bool _rebuildingSyncEngine = false;
  bool _pendingRebuildFingerprint = false;
  bool _syncFolderPassRunning = false;
  bool _pendingSyncFolderPass = false;
  AppSection _section = AppSection.files;
  String? _syncFolder;
  bool _selectingFolder = false;
  String? _recoveredCameraPhotoPath;

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
    _syncFolderWatcher = SyncFolderWatcher(onChange: _runSyncFolderPass);
    _cameraPhotoPicker =
        widget.cameraPhotoPicker ?? ImagePickerCameraPhotoPicker();
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
    if (_syncEngine?.isPaused != true) _syncFolderWatcher.start(saved);
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
  Future<void> _runSyncFolderPass() async {
    final folder = _syncFolder;
    final engine = _syncEngine;
    final materializer = _syncFolderMaterializer;
    final uploader = _localFolderUploader;
    if (folder == null ||
        engine == null ||
        engine.isPaused ||
        materializer == null ||
        uploader == null) {
      return;
    }
    if (_syncFolderPassRunning) {
      _pendingSyncFolderPass = true;
      return;
    }
    _syncFolderPassRunning = true;
    try {
      await materializer.materialize(folder);
      await uploader.scan(folder);
    } finally {
      _syncFolderPassRunning = false;
    }
    if (_pendingSyncFolderPass) {
      _pendingSyncFolderPass = false;
      await _runSyncFolderPass();
    }
  }

  void _toggleSyncPause() {
    final engine = _syncEngine;
    if (engine == null) return;
    if (engine.isPaused) {
      engine.resume();
      final folder = _syncFolder;
      if (folder != null) _syncFolderWatcher.start(folder);
      unawaited(_runSyncFolderPass());
    } else {
      _syncFolderWatcher.stop();
      engine.pause();
    }
  }

  @override
  void dispose() {
    _serverConnectionController.removeListener(_onServerConnectionChanged);
    _vaultSetupController.removeListener(_maybeRefreshFiles);
    _filesController?.dispose();
    _syncFolderMaterializer?.dispose();
    _localFolderUploader?.dispose();
    _syncFolderWatcher.dispose();
    _syncEngine?.dispose();
    _vaultSetupController.dispose();
    _deviceProvisioningController.dispose();
    _deviceSetupController.dispose();
    _serverConnectionController.dispose();
    super.dispose();
  }

  Future<void> _selectSyncFolder() async {
    setState(() => _selectingFolder = true);
    try {
      final folder = await getDirectoryPath(
        confirmButtonText: 'Use as HomeBox folder',
      );
      if (!mounted || folder == null) return;
      setState(() => _syncFolder = folder);
      await _syncFolderStore.save(folder);
      if (_syncEngine?.isPaused != true) _syncFolderWatcher.start(folder);
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

  @override
  Widget build(BuildContext context) {
    final wideLayout = MediaQuery.sizeOf(context).width >= 720;
    final content = _SectionContent(
      section: _section,
      syncFolder: _syncFolder,
      selectingFolder: _selectingFolder,
      onSelectSyncFolder: _selectSyncFolder,
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
      onCapturePhoto: supportsCameraCapture(defaultTargetPlatform)
          ? _capturePhoto
          : null,
    );
    if (!wideLayout) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('HomeBox'),
          actions: [_VaultStateChip(controller: _vaultSetupController)],
        ),
        body: content,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _section.index,
          onDestinationSelected: (index) =>
              setState(() => _section = AppSection.values[index]),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Files',
            ),
            NavigationDestination(
              icon: Icon(Icons.sync_outlined),
              selectedIcon: Icon(Icons.sync),
              label: 'Sync',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      );
    }
    return Scaffold(
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
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: Text('Files'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.sync_outlined),
                  selectedIcon: Icon(Icons.sync),
                  label: Text('Sync'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('Settings'),
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
                        const Spacer(),
                        _VaultStateChip(controller: _vaultSetupController),
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
    );
  }
}

class _VaultStateChip extends StatelessWidget {
  const _VaultStateChip({required this.controller});

  final VaultSetupController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final ready = controller.status == VaultSetupStatus.ready;
      return Tooltip(
        message: ready
            ? 'This vault was created on this device. A trusted device or Recovery Secret is required on any other device.'
            : 'Create or restore this account\'s vault in Settings to unlock E2EE data.',
        child: Chip(
          avatar: Icon(
            ready ? Icons.lock_open_outlined : Icons.lock_outline,
            size: 18,
          ),
          label: Text(ready ? 'Vault unlocked' : 'Vault locked'),
        ),
      );
    },
  );
}

class _SectionContent extends StatelessWidget {
  const _SectionContent({
    required this.section,
    required this.syncFolder,
    required this.selectingFolder,
    required this.onSelectSyncFolder,
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
    required this.onCapturePhoto,
  });

  final AppSection section;
  final String? syncFolder;
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;
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
  final Future<void> Function()? onCapturePhoto;

  @override
  Widget build(BuildContext context) => switch (section) {
    AppSection.files => _FilesSection(
      controller: filesController,
      onCapturePhoto: onCapturePhoto,
    ),
    AppSection.sync => _SyncSection(
      syncFolder: syncFolder,
      onSelectSyncFolder: onSelectSyncFolder,
      syncEngine: syncEngine,
      syncFolderMaterializer: syncFolderMaterializer,
      localFolderUploader: localFolderUploader,
      syncFolderWatcher: syncFolderWatcher,
      onToggleSyncPause: onToggleSyncPause,
    ),
    AppSection.settings => _SettingsSection(
      deviceSetupController: deviceSetupController,
      deviceProvisioningController: deviceProvisioningController,
      serverConnectionController: serverConnectionController,
      vaultSetupController: vaultSetupController,
      onVaultProvisioned: onVaultProvisioned,
    ),
  };
}

final class _FilesSection extends StatefulWidget {
  const _FilesSection({required this.controller, required this.onCapturePhoto});

  final FilesController? controller;
  final Future<void> Function()? onCapturePhoto;

  @override
  State<_FilesSection> createState() => _FilesSectionState();
}

final class _FilesSectionState extends State<_FilesSection> {
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

  Future<void> _uploadFile(BuildContext context) async {
    final controller = widget.controller;
    if (controller == null) return;
    final file = await openFile();
    if (file == null) return;
    final ok = await controller.uploadFile(file.path);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.errorMessage ?? 'Upload failed.')),
      );
    }
  }

  Future<void> _downloadFile(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final destination = await getSaveLocation(suggestedName: entry.name);
    if (destination == null) return;
    final ok = await controller.downloadFile(entry, destination.path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Saved to ${destination.path}'
                : (controller.errorMessage ?? 'Download failed.'),
          ),
        ),
      );
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
    final result = await controller.uploadFiles(paths);
    if (!mounted || result.total == 0) return;
    final message = switch ((result.succeeded, result.failed)) {
      (0, final failed) =>
        controller.errorMessage ?? 'Could not upload $failed dropped file(s).',
      (final succeeded, 0) => 'Encrypted and uploaded $succeeded file(s).',
      (final succeeded, final failed) =>
        'Uploaded $succeeded file(s); $failed file(s) could not be uploaded.',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
        final Widget body;
        if (controller.status == FilesStatus.idle) {
          body = const _FilesMessageState(
            icon: Icons.cloud_off_outlined,
            message: 'Connect to a server, sign in, and set up the vault in Settings to see your files.',
          );
        } else if (controller.status == FilesStatus.failed) {
          body = _FilesMessageState(
            icon: Icons.error_outline,
            message: controller.errorMessage ?? 'Files are unavailable.',
          );
        } else if (controller.status == FilesStatus.loading &&
            controller.entries.isEmpty) {
          body = const Center(child: CircularProgressIndicator());
        } else if (controller.entries.isEmpty) {
          body = const _FilesMessageState(
            icon: Icons.folder_open_outlined,
            message: 'This folder is empty.',
          );
        } else {
          body = ListView.separated(
            itemCount: controller.entries.length,
            separatorBuilder: (context, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = controller.entries[index];
              return ListTile(
                leading: Icon(
                  entry.isDirectory
                      ? Icons.folder_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(entry.name),
                subtitle: entry.isDirectory
                    ? null
                    : Text(entry.metadata.mimeType ?? 'Encrypted file'),
                onTap: entry.isDirectory
                    ? () => controller.openFolder(entry)
                    : () => _downloadFile(context, entry),
                trailing: PopupMenuButton<String>(
                  tooltip: 'More actions',
                  onSelected: (value) => switch (value) {
                    'replace' => _replaceContent(context, entry),
                    'rename' => _renameEntry(context, entry),
                    'delete' => _deleteEntry(context, entry),
                    _ => null,
                  },
                  itemBuilder: (context) => [
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
          title: 'Files',
          subtitle: controller.breadcrumbNames.isEmpty
              ? 'Root'
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
                  if (controller.canGoUp)
                    IconButton(
                      onPressed: controller.goToRoot,
                      icon: const Icon(Icons.home_outlined),
                      tooltip: 'Root',
                    ),
                  if (controller.busy)
                    SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: controller.progress,
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => _createFolder(context),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('New folder'),
                  ),
                  if (widget.onCapturePhoto != null)
                    FilledButton.tonalIcon(
                      onPressed: controller.busy ? null : widget.onCapturePhoto,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Camera'),
                    ),
                  FilledButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => _uploadFile(context),
                    icon: const Icon(Icons.upload_outlined),
                    label: const Text('Upload'),
                  ),
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
              Expanded(child: body),
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
    required this.syncEngine,
    required this.syncFolderMaterializer,
    required this.localFolderUploader,
    required this.syncFolderWatcher,
    required this.onToggleSyncPause,
  });
  final String? syncFolder;
  final Future<void> Function() onSelectSyncFolder;
  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final LocalFolderUploader? localFolderUploader;
  final SyncFolderWatcher syncFolderWatcher;
  final VoidCallback onToggleSyncPause;

  @override
  Widget build(BuildContext context) {
    final engine = syncEngine;
    return _PageFrame(
      title: 'Sync',
      subtitle: engine == null
          ? 'Sync is paused while the E2EE vault is locked.'
          : 'The local cache and outbox sync with the server automatically.',
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
              animation: engine,
              builder: (context, _) {
                final (icon, label) = switch (engine.status) {
                  SyncStatus.idle => (Icons.check_circle_outline, 'Up to date'),
                  SyncStatus.syncing => (Icons.sync, 'Syncing…'),
                  SyncStatus.paused => (
                    Icons.pause_circle_outline,
                    'Sync paused',
                  ),
                  SyncStatus.offline => (Icons.cloud_off_outlined, 'Offline'),
                  SyncStatus.error => (Icons.error_outline, 'Sync error'),
                };
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        engine.status == SyncStatus.error &&
                            engine.errorMessage != null
                        ? Text(engine.errorMessage!)
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
              trailing: TextButton(
                onPressed: onSelectSyncFolder,
                child: Text(syncFolder == null ? 'Choose' : 'Change'),
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
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        materializer.status == SyncFolderStatus.error &&
                            materializer.errorMessage != null
                        ? Text(materializer.errorMessage!)
                        : null,
                  ),
                );
              },
            ),
          if (syncFolder != null && localFolderUploader != null)
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
                  LocalUploadStatus.error => (
                    Icons.error_outline,
                    'Could not upload local changes',
                  ),
                };
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        uploader.status == LocalUploadStatus.error &&
                            uploader.errorMessage != null
                        ? Text(uploader.errorMessage!)
                        : null,
                  ),
                );
              },
            ),
          if (syncFolder != null)
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

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.deviceSetupController,
    required this.deviceProvisioningController,
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.onVaultProvisioned,
  });

  final DeviceSetupController deviceSetupController;
  final DeviceProvisioningController deviceProvisioningController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final Future<void> Function() onVaultProvisioned;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Settings',
    subtitle: 'Connection and device security.',
    child: ListView(
      children: [
        _ServerConnectionCard(controller: serverConnectionController),
        _DeviceIdentityCard(controller: deviceSetupController),
        _DeviceProvisioningCard(
          controller: deviceProvisioningController,
          deviceSetupController: deviceSetupController,
          serverConnectionController: serverConnectionController,
          vaultSetupController: vaultSetupController,
          onVaultProvisioned: onVaultProvisioned,
        ),
        _ApprovedDevicesCard(
          controller: deviceProvisioningController,
          serverConnectionController: serverConnectionController,
        ),
        _VaultSetupCard(
          controller: vaultSetupController,
          serverConnectionController: serverConnectionController,
        ),
        const _AutostartCard(),
      ],
    ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve this device?'),
        content: Text(
          'HomeBox will encrypt this vault key for ${target.name}. Verify that this is the device you just signed in on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final approved = await controller.provisionDevice(target);
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

final class _ApprovedDevicesCard extends StatefulWidget {
  const _ApprovedDevicesCard({
    required this.controller,
    required this.serverConnectionController,
  });

  final DeviceProvisioningController controller;
  final ServerConnectionController serverConnectionController;

  @override
  State<_ApprovedDevicesCard> createState() => _ApprovedDevicesCardState();
}

final class _ApprovedDevicesCardState extends State<_ApprovedDevicesCard> {
  List<transport.HomeBoxDevice> _devices = const [];
  bool _loading = false;
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
    final devices = await widget.controller.approvedDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _error = widget.controller.errorMessage;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final signedIn =
        widget.serverConnectionController.status ==
        ServerConnectionStatus.authenticated;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.devices_other_outlined),
              title: const Text('Approved devices'),
              subtitle: const Text(
                'Devices that have successfully contacted the server sync feed.',
              ),
              trailing: IconButton(
                tooltip: 'Refresh approved devices',
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
                  child: Text('No approved device has synchronized yet.'),
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
                  ),
                  title: Text('${device.name} (${_deviceCode(device.id)})'),
                  subtitle: Text(
                    'Last synchronization: ${_formatLocalDateTime(device.lastSyncAt!)}',
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
  });

  final VaultSetupController controller;
  final ServerConnectionController serverConnectionController;

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
    if (context.mounted) await _showRecoverySecret(context, secret);
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
