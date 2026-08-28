import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/e2ee/device_identity.dart';
import 'core/e2ee/vault_key_store.dart';
import 'core/storage/local_database.dart';
import 'features/device/device_setup_controller.dart';
import 'features/files/files_controller.dart';
import 'features/server/server_connection_controller.dart';
import 'features/sync/sync_engine.dart';
import 'features/syncfolder/local_folder_uploader.dart';
import 'features/syncfolder/sync_folder_materializer.dart';
import 'features/syncfolder/sync_folder_store.dart';
import 'features/syncfolder/sync_folder_watcher.dart';
import 'features/vault/vault_setup_controller.dart';

void main() => runApp(const HomeBoxApp());

class HomeBoxApp extends StatelessWidget {
  const HomeBoxApp({
    super.key,
    this.deviceIdentityStore,
    this.serverConnectionController,
    this.vaultKeyStore,
    this.syncFolderStore,
  });

  final DeviceIdentityStore? deviceIdentityStore;
  final ServerConnectionController? serverConnectionController;
  final VaultKeyStore? vaultKeyStore;
  final SyncFolderStore? syncFolderStore;

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
  });

  final DeviceIdentityStore? deviceIdentityStore;

  // Overridable purely so tests can supply in-memory-backed instances
  // instead of ones backed by real OS secure storage (see widget_test.dart)
  // — matching the same reason deviceIdentityStore above is overridable.
  final ServerConnectionController? serverConnectionController;
  final VaultKeyStore? vaultKeyStore;
  final SyncFolderStore? syncFolderStore;

  @override
  State<HomeBoxDesktopPage> createState() => _HomeBoxDesktopPageState();
}

class _HomeBoxDesktopPageState extends State<HomeBoxDesktopPage> {
  late final DeviceIdentityStore _deviceIdentityStore;
  late final DeviceSetupController _deviceSetupController;
  late final ServerConnectionController _serverConnectionController;
  late final VaultKeyStore _vaultKeyStore;
  late final VaultSetupController _vaultSetupController;
  late final SyncFolderStore _syncFolderStore;
  late final SyncFolderWatcher _syncFolderWatcher;
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
    _syncFolderStore = widget.syncFolderStore ?? SyncFolderStore();
    _syncFolderWatcher = SyncFolderWatcher(onChange: _runSyncFolderPass);
    unawaited(_deviceSetupController.initialize());
    unawaited(_initializeServerConnection());
    unawaited(_vaultSetupController.initialize());
    unawaited(_loadSyncFolder());
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
    _syncFolderWatcher.start(saved);
    unawaited(_runSyncFolderPass());
  }

  void _onServerConnectionChanged() {
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
    }
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
    final materializer = _syncFolderMaterializer;
    final uploader = _localFolderUploader;
    if (folder == null || materializer == null || uploader == null) return;
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
      _syncFolderWatcher.start(folder);
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
      serverConnectionController: _serverConnectionController,
      vaultSetupController: _vaultSetupController,
      filesController: _filesController,
      syncEngine: _syncEngine,
      syncFolderMaterializer: _syncFolderMaterializer,
      localFolderUploader: _localFolderUploader,
      syncFolderWatcher: _syncFolderWatcher,
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
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.filesController,
    required this.syncEngine,
    required this.syncFolderMaterializer,
    required this.localFolderUploader,
    required this.syncFolderWatcher,
  });

  final AppSection section;
  final String? syncFolder;
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;
  final DeviceSetupController deviceSetupController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final FilesController? filesController;
  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final LocalFolderUploader? localFolderUploader;
  final SyncFolderWatcher syncFolderWatcher;

  @override
  Widget build(BuildContext context) => switch (section) {
    AppSection.files => _FilesSection(controller: filesController),
    AppSection.sync => _SyncSection(
      syncFolder: syncFolder,
      onSelectSyncFolder: onSelectSyncFolder,
      syncEngine: syncEngine,
      syncFolderMaterializer: syncFolderMaterializer,
      localFolderUploader: localFolderUploader,
      syncFolderWatcher: syncFolderWatcher,
    ),
    AppSection.settings => _SettingsSection(
      deviceSetupController: deviceSetupController,
      serverConnectionController: serverConnectionController,
      vaultSetupController: vaultSetupController,
    ),
  };
}

final class _FilesSection extends StatelessWidget {
  const _FilesSection({required this.controller});

  final FilesController? controller;

  Future<void> _createFolder(BuildContext context) async {
    final controller = this.controller;
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
    final controller = this.controller;
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
    final controller = this.controller;
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
    final controller = this.controller;
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
    final controller = this.controller;
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
    final controller = this.controller;
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

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
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
              Row(
                children: [
                  if (controller.canGoUp)
                    IconButton(
                      onPressed: controller.goToRoot,
                      icon: const Icon(Icons.home_outlined),
                      tooltip: 'Root',
                    ),
                  const Spacer(),
                  if (controller.busy)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: controller.progress,
                        ),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => _createFolder(context),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('New folder'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => _uploadFile(context),
                    icon: const Icon(Icons.upload_outlined),
                    label: const Text('Upload'),
                  ),
                ],
              ),
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
  });
  final String? syncFolder;
  final Future<void> Function() onSelectSyncFolder;
  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final LocalFolderUploader? localFolderUploader;
  final SyncFolderWatcher syncFolderWatcher;

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
                        : null,
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
    required this.serverConnectionController,
    required this.vaultSetupController,
  });

  final DeviceSetupController deviceSetupController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Settings',
    subtitle: 'Connection and device security.',
    child: ListView(
      children: [
        _ServerConnectionCard(controller: serverConnectionController),
        _DeviceIdentityCard(controller: deviceSetupController),
        _VaultSetupCard(
          controller: vaultSetupController,
          serverConnectionController: serverConnectionController,
        ),
      ],
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
        title: const Text('Prepare this Windows device?'),
        content: const Text(
          'HomeBox will create an X25519 private key protected by Windows secure storage. '
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
        DeviceSetupStatus.checking => 'Checking Windows secure storage…',
        DeviceSetupStatus.missing =>
          'No device identity. Create one before requesting provisioning.',
        DeviceSetupStatus.creating =>
          'Creating a device-bound X25519 identity…',
        DeviceSetupStatus.ready =>
          'Identity ready · Not provisioned\nFingerprint: $fingerprint',
        DeviceSetupStatus.failed =>
          'Windows secure storage is unavailable or contains invalid data.',
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
          title: const Text('This Windows device'),
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
